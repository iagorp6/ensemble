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
			routes(newRegistry(), "").ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))

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
	routes(newRegistry(), "").ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

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

// =============================================================================
// The backstage secret (layer 5)
// =============================================================================

const testToken = "s3cr3t-from-sops"

func TestPrivateEndpointAuthorisation(t *testing.T) {
	tests := []struct {
		name       string
		token      string // what the server was given
		authHeader string // what the client sent
		wantStatus int
	}{
		// 503 not 401, because the distinction is what tells you whether to
		// debug the client or the deployment.
		{"no secret delivered", "", "Bearer " + testToken, http.StatusServiceUnavailable},
		{"no header", testToken, "", http.StatusUnauthorized},
		{"wrong scheme", testToken, "Basic " + testToken, http.StatusUnauthorized},
		{"bare token, no scheme", testToken, testToken, http.StatusUnauthorized},
		{"wrong token", testToken, "Bearer nope", http.StatusUnauthorized},
		// A prefix of the real token must not pass. This is the case a naive
		// strings.HasPrefix check would wave through.
		{"prefix of the real token", testToken, "Bearer s3cr3t", http.StatusUnauthorized},
		{"correct token", testToken, "Bearer " + testToken, http.StatusOK},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ready.Store(true)
			t.Cleanup(func() { ready.Store(false) })

			req := httptest.NewRequest(http.MethodGet, "/private", nil)
			if tc.authHeader != "" {
				req.Header.Set("Authorization", tc.authHeader)
			}
			rec := httptest.NewRecorder()
			routes(newRegistry(), tc.token).ServeHTTP(rec, req)

			if rec.Code != tc.wantStatus {
				t.Errorf("got status %d, want %d (body: %s)", rec.Code, tc.wantStatus, rec.Body.String())
			}
			// A 401 without WWW-Authenticate is a protocol violation, and it's
			// the sort of thing that only bites when a real client is involved.
			if rec.Code == http.StatusUnauthorized && rec.Header().Get("WWW-Authenticate") == "" {
				t.Error("401 response is missing the WWW-Authenticate header")
			}
		})
	}
}

func TestInfoReportsTokenPresenceNotValue(t *testing.T) {
	for _, tc := range []struct {
		name  string
		token string
		want  bool
	}{
		{"secret delivered", testToken, true},
		{"no secret", "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ready.Store(true)
			t.Cleanup(func() { ready.Store(false) })

			rec := httptest.NewRecorder()
			routes(newRegistry(), tc.token).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

			var got infoResponse
			if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
				t.Fatalf("bad JSON: %v", err)
			}
			if got.TokenConfigured != tc.want {
				t.Errorf("tokenConfigured: got %v, want %v", got.TokenConfigured, tc.want)
			}
		})
	}
}

// THE TEST THAT MATTERS MOST IN THIS LAYER.
//
// The entire point of `backstage` is that a secret can live in a public
// repository without being readable. All of that is undone if the running
// service hands the value to anyone who asks — and that kind of leak arrives by
// accident, in a debug field someone added at 2am, not by design.
//
// So: sweep every endpoint, authenticated and not, and assert the token appears
// in no response body and no response header.
func TestTokenNeverAppearsInAnyResponse(t *testing.T) {
	ready.Store(true)
	t.Cleanup(func() { ready.Store(false) })

	h := routes(newRegistry(), testToken)

	requests := []struct {
		path string
		auth string
	}{
		{"/", ""},
		{"/healthz", ""},
		{"/readyz", ""},
		{"/metrics", ""},
		{"/private", ""},
		{"/private", "Bearer wrong"},
		{"/private", "Bearer " + testToken}, // even when correctly authenticated
	}

	for _, rq := range requests {
		req := httptest.NewRequest(http.MethodGet, rq.path, nil)
		if rq.auth != "" {
			req.Header.Set("Authorization", rq.auth)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if strings.Contains(rec.Body.String(), testToken) {
			t.Errorf("GET %s (auth=%q) leaked the token in its body:\n%s", rq.path, rq.auth, rec.Body.String())
		}
		for name, values := range rec.Header() {
			for _, v := range values {
				if strings.Contains(v, testToken) {
					t.Errorf("GET %s leaked the token in header %s: %s", rq.path, name, v)
				}
			}
		}
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
