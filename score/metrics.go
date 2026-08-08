package main

import (
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// =============================================================================
// A minimal Prometheus exposition-format endpoint, written by hand.
// =============================================================================
//
// Prometheus scrapes plain text over HTTP. That's the whole protocol. A metric
// looks like:
//
//	# HELP overture_requests_total Total HTTP requests handled.
//	# TYPE overture_requests_total counter
//	overture_requests_total{method="GET",path="/",status="200"} 42
//
// Three metric types matter here:
//
//	counter   only goes up. Restarts reset it to zero, which is why you always
//	          query it with rate() rather than reading the raw value.
//	gauge     goes up and down. Current temperature, current uptime.
//	histogram counts observations into cumulative buckets. This is the one
//	          people get wrong, so see below.
//
// `metronome` (layer 6) scrapes this. The annotations that tell it to are
// already on the Deployment in conductor/manifests/overture/.

const namespace = "overture"

// Histogram buckets, in seconds. Each bucket counts every observation LESS THAN
// OR EQUAL TO its upper bound — they're cumulative, not exclusive ranges. So a
// 3ms request increments the 0.005 bucket AND every bucket above it.
//
// That cumulative property is what makes histogram_quantile() work: Prometheus
// can interpolate a p99 from the bucket boundaries without storing every
// observation. The cost is that your percentile accuracy is limited by how well
// the buckets straddle the real latency distribution — buckets chosen badly
// give you a confidently wrong p99.
//
// These are tuned for a service that should answer in single-digit
// milliseconds, with headroom to see it degrade.
var durationBuckets = []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 1, 5}

type labelKey struct {
	method string
	path   string
	status string
}

type registry struct {
	mu sync.Mutex

	startedAt time.Time

	requests map[labelKey]uint64

	// One histogram per path. bucketCounts[i] is the count for
	// durationBuckets[i]; +Inf is derived from count.
	bucketCounts map[string][]uint64
	sum          map[string]float64
	count        map[string]uint64
}

func newRegistry() *registry {
	return &registry{
		startedAt:    time.Now(),
		requests:     make(map[labelKey]uint64),
		bucketCounts: make(map[string][]uint64),
		sum:          make(map[string]float64),
		count:        make(map[string]uint64),
	}
}

// observe records one completed request. Called from the middleware, so it runs
// on every request on every goroutine — hence the mutex.
func (r *registry) observe(method, path, status string, d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.requests[labelKey{method: method, path: path, status: status}]++

	if _, ok := r.bucketCounts[path]; !ok {
		r.bucketCounts[path] = make([]uint64, len(durationBuckets))
	}
	secs := d.Seconds()
	for i, ub := range durationBuckets {
		if secs <= ub {
			// Cumulative: increment this bucket and every larger one.
			for j := i; j < len(durationBuckets); j++ {
				r.bucketCounts[path][j]++
			}
			break
		}
	}
	r.sum[path] += secs
	r.count[path]++
}

// escapeLabel escapes a Prometheus label value. Backslash, double quote and
// newline are the only three characters the format cares about — but getting
// this wrong produces a scrape error rather than a wrong number, so it's worth
// the six lines.
func escapeLabel(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	return s
}

// render writes the full exposition text. Deterministically ordered, because a
// stable output is what makes the format testable.
func (r *registry) render() string {
	r.mu.Lock()
	defer r.mu.Unlock()

	var b strings.Builder

	// build_info is the idiomatic way to expose version metadata: a gauge whose
	// value is always 1, carrying the interesting data in its labels. It lets a
	// query join runtime metrics against the build that produced them —
	// "show me error rate by version" during a rollout.
	fmt.Fprintf(&b, "# HELP %s_build_info Build metadata. Always 1; the labels carry the payload.\n", namespace)
	fmt.Fprintf(&b, "# TYPE %s_build_info gauge\n", namespace)
	fmt.Fprintf(&b, "%s_build_info{version=\"%s\",commit=\"%s\",built=\"%s\"} 1\n",
		namespace, escapeLabel(version), escapeLabel(commit), escapeLabel(buildDate))

	fmt.Fprintf(&b, "# HELP %s_uptime_seconds Seconds since this process started.\n", namespace)
	fmt.Fprintf(&b, "# TYPE %s_uptime_seconds gauge\n", namespace)
	fmt.Fprintf(&b, "%s_uptime_seconds %.3f\n", namespace, time.Since(r.startedAt).Seconds())

	fmt.Fprintf(&b, "# HELP %s_requests_total Total HTTP requests handled.\n", namespace)
	fmt.Fprintf(&b, "# TYPE %s_requests_total counter\n", namespace)
	keys := make([]labelKey, 0, len(r.requests))
	for k := range r.requests {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].path != keys[j].path {
			return keys[i].path < keys[j].path
		}
		if keys[i].method != keys[j].method {
			return keys[i].method < keys[j].method
		}
		return keys[i].status < keys[j].status
	})
	for _, k := range keys {
		fmt.Fprintf(&b, "%s_requests_total{method=\"%s\",path=\"%s\",status=\"%s\"} %d\n",
			namespace, escapeLabel(k.method), escapeLabel(k.path), escapeLabel(k.status), r.requests[k])
	}

	fmt.Fprintf(&b, "# HELP %s_request_duration_seconds Request latency.\n", namespace)
	fmt.Fprintf(&b, "# TYPE %s_request_duration_seconds histogram\n", namespace)
	paths := make([]string, 0, len(r.count))
	for p := range r.count {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		for i, ub := range durationBuckets {
			fmt.Fprintf(&b, "%s_request_duration_seconds_bucket{path=\"%s\",le=\"%s\"} %d\n",
				namespace, escapeLabel(p), strconv.FormatFloat(ub, 'g', -1, 64), r.bucketCounts[p][i])
		}
		// The +Inf bucket is mandatory and must equal the total count. Prometheus
		// rejects a histogram without it.
		fmt.Fprintf(&b, "%s_request_duration_seconds_bucket{path=\"%s\",le=\"+Inf\"} %d\n",
			namespace, escapeLabel(p), r.count[p])
		fmt.Fprintf(&b, "%s_request_duration_seconds_sum{path=\"%s\"} %f\n", namespace, escapeLabel(p), r.sum[p])
		fmt.Fprintf(&b, "%s_request_duration_seconds_count{path=\"%s\"} %d\n", namespace, escapeLabel(p), r.count[p])
	}

	return b.String()
}

func (r *registry) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = w.Write([]byte(r.render()))
	}
}
