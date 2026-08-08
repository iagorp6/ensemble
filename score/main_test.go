package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Table-driven tests are the Go idiom: one test function, a slice of cases,
// t.Run for a named subtest each. A failure names the case rather than a line
// number, and adding a case is one line rather than one function.

func TestEndpointStatus(t *testing.T) {
	tests := []struct {
		name       string
		path       string
		ready      bool
		wantStatus int
	}{
		{"info", "/", true, http.StatusOK},
		{"liveness is always ok", "/healthz", true, http.StatusOK},
		// Liveness must NOT depend on readiness. If it did, draining a pod
		// would also get it killed mid-drain, which defeats the whole point of
		// the graceful shutdown sequence in main.go.
		{"liveness ok even while draining", "/healthz", false, http.StatusOK},
		{"readiness ok when ready", "/readyz", true, http.StatusOK},
		{"readiness fails while draining", "/readyz", false, http.StatusServiceUnavailable},
		{"metrics", "/metrics", true, http.StatusOK},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ready.Store(tc.ready)
			t.Cleanup(func() { ready.Store(false) })

			rec := httptest.NewRecorder()
			routes(newRegistry()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))

			if rec.Code != tc.wantStatus {
				t.Errorf("GET %s: got status %d, want %d", tc.path, rec.Code, tc.wantStatus)
			}
		})
	}
}

func TestInfoPayload(t *testing.T) {
	ready.Store(true)
	t.Cleanup(func() { ready.Store(false) })

	rec := httptest.NewRecorder()
	routes(newRegistry()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	var got infoResponse
	if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
		t.Fatalf("response is not valid JSON: %v", err)
	}
	if got.Name != "overture" {
		t.Errorf("name: got %q, want %q", got.Name, "overture")
	}
	// The build stamp must be reported, not silently empty — a version field
	// that is always "" looks like it works right up until you need it during
	// an incident.
	if got.Version == "" || got.Commit == "" {
		t.Errorf("build metadata missing: version=%q commit=%q", got.Version, got.Commit)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("content-type: got %q, want application/json", ct)
	}
}

func TestMetricsExpositionFormat(t *testing.T) {
	reg := newRegistry()
	reg.observe("GET", "/", "2xx", 3*time.Millisecond)

	out := reg.render()

	// Every metric needs its HELP and TYPE lines. Prometheus tolerates their
	// absence, but without them nothing downstream can tell a counter from a
	// gauge, and rate() on a gauge is silently meaningless.
	required := []string{
		"# HELP overture_build_info",
		"# TYPE overture_build_info gauge",
		"# TYPE overture_uptime_seconds gauge",
		"# TYPE overture_requests_total counter",
		"# TYPE overture_request_duration_seconds histogram",
		`overture_requests_total{method="GET",path="/",status="2xx"} 1`,
		`overture_request_duration_seconds_count{path="/"} 1`,
	}
	for _, want := range required {
		if !strings.Contains(out, want) {
			t.Errorf("exposition output missing %q\n--- got ---\n%s", want, out)
		}
	}
}

func TestHistogramBucketsAreCumulative(t *testing.T) {
	reg := newRegistry()
	// 3ms lands in the 0.005 bucket, so 0.001 must be 0 and everything from
	// 0.005 upward must be 1.
	reg.observe("GET", "/", "2xx", 3*time.Millisecond)

	out := reg.render()

	cases := []struct {
		le   string
		want string
	}{
		{"0.001", `overture_request_duration_seconds_bucket{path="/",le="0.001"} 0`},
		{"0.005", `overture_request_duration_seconds_bucket{path="/",le="0.005"} 1`},
		{"0.01", `overture_request_duration_seconds_bucket{path="/",le="0.01"} 1`},
		{"5", `overture_request_duration_seconds_bucket{path="/",le="5"} 1`},
		// +Inf is mandatory and must equal the total count. Prometheus rejects
		// a histogram without it.
		{"+Inf", `overture_request_duration_seconds_bucket{path="/",le="+Inf"} 1`},
	}
	for _, tc := range cases {
		t.Run("le="+tc.le, func(t *testing.T) {
			if !strings.Contains(out, tc.want) {
				t.Errorf("missing %q\n--- got ---\n%s", tc.want, out)
			}
		})
	}
}

func TestObservationAboveTopBucketStillCounted(t *testing.T) {
	reg := newRegistry()
	// 10s exceeds every defined bucket. It must still land in +Inf and in the
	// count — an observation that vanishes because it was slower than expected
	// is the worst possible thing to lose.
	reg.observe("GET", "/", "2xx", 10*time.Second)

	out := reg.render()
	if !strings.Contains(out, `overture_request_duration_seconds_bucket{path="/",le="+Inf"} 1`) {
		t.Errorf("slow request not counted in +Inf\n--- got ---\n%s", out)
	}
	if !strings.Contains(out, `overture_request_duration_seconds_count{path="/"} 1`) {
		t.Errorf("slow request not counted in _count\n--- got ---\n%s", out)
	}
}

// THE CARDINALITY GUARD.
//
// Labelling with the raw URL path turns every distinct URL into its own time
// series. One /echo/{id} endpoint with a million ids is a million series, and
// unbounded label cardinality is the standard way to take a Prometheus server
// down. The middleware must record the ROUTE PATTERN instead.
func TestMetricsLabelUsesRoutePatternNotRawPath(t *testing.T) {
	reg := newRegistry()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /echo/{id}", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	h := instrument(reg, mux)

	for _, id := range []string{"1", "2", "3"} {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/echo/"+id, nil))
	}

	out := reg.render()
	if strings.Contains(out, `path="/echo/1"`) {
		t.Errorf("raw URL leaked into a metric label — unbounded cardinality\n--- got ---\n%s", out)
	}
	if !strings.Contains(out, `overture_requests_total{method="GET",path="GET /echo/{id}",status="2xx"} 3`) {
		t.Errorf("three requests to one route should be one series with value 3\n--- got ---\n%s", out)
	}
}

func TestStatusBucketing(t *testing.T) {
	tests := []struct {
		code int
		want string
	}{
		{200, "2xx"}, {201, "2xx"}, {301, "3xx"},
		{404, "4xx"}, {418, "4xx"}, {500, "5xx"}, {503, "5xx"},
	}
	for _, tc := range tests {
		if got := statusText(tc.code); got != tc.want {
			t.Errorf("statusText(%d): got %q, want %q", tc.code, got, tc.want)
		}
	}
}

func TestLabelEscaping(t *testing.T) {
	tests := []struct {
		in, want string
	}{
		{`plain`, `plain`},
		{`has"quote`, `has\"quote`},
		{`has\backslash`, `has\\backslash`},
		{"has\nnewline", `has\nnewline`},
	}
	for _, tc := range tests {
		if got := escapeLabel(tc.in); got != tc.want {
			t.Errorf("escapeLabel(%q): got %q, want %q", tc.in, got, tc.want)
		}
	}
}

// Concurrency check. The middleware runs on every request on every goroutine,
// so the registry has to be safe under parallel writes. Run with -race and this
// fails loudly if the locking is wrong.
func TestRegistryIsConcurrencySafe(t *testing.T) {
	reg := newRegistry()
	done := make(chan struct{})

	for i := 0; i < 50; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			for j := 0; j < 100; j++ {
				reg.observe("GET", "/", "2xx", time.Millisecond)
			}
		}()
	}
	for i := 0; i < 50; i++ {
		<-done
	}

	if !strings.Contains(reg.render(), `overture_requests_total{method="GET",path="/",status="2xx"} 5000`) {
		t.Errorf("lost updates under concurrency\n--- got ---\n%s", reg.render())
	}
}
