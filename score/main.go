// Command overture is the demo service this platform builds and deploys.
//
// It is the "opening piece" — the first thing the ensemble plays, and the first
// workload to travel the whole path: `score` builds it, GHCR stores it,
// `conductor` deploys it, `metronome` scrapes it.
//
// It's deliberately small. The interesting part of this layer is the pipeline
// around the app, not the app. What it does have is everything the rest of the
// platform actually needs from a real service: distinct liveness and readiness
// signals, Prometheus metrics, build metadata stamped in at compile time, and
// a correct response to SIGTERM.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

// Stamped at build time with -ldflags. See the Dockerfile.
//
// The alternative is reading a VERSION file at runtime, which means the running
// process can disagree with the image it came from. Compiling the value in
// makes that impossible: this binary cannot report a version it wasn't built
// as.
var (
	version   = "dev"
	commit    = "none"
	buildDate = "unknown"
)

const (
	defaultAddr = ":9898"

	// How long to keep serving after SIGTERM. See gracefulShutdown.
	shutdownGrace = 15 * time.Second
)

// ready gates the readiness probe. Starts false, flips true once the server is
// listening, and flips back to false the moment SIGTERM arrives.
var ready atomic.Bool

type infoResponse struct {
	Name      string `json:"name"`
	Version   string `json:"version"`
	Commit    string `json:"commit"`
	BuildDate string `json:"buildDate"`
	Hostname  string `json:"hostname"`
	Message   string `json:"message"`
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	addr := defaultAddr
	if v := os.Getenv("OVERTURE_ADDR"); v != "" {
		addr = v
	}

	reg := newRegistry()
	srv := &http.Server{
		Addr:              addr,
		Handler:           routes(reg),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	if err := run(srv, logger); err != nil {
		logger.Error("server stopped with error", "err", err)
		os.Exit(1)
	}
}

func run(srv *http.Server, logger *slog.Logger) error {
	// NotifyContext cancels ctx when SIGTERM or SIGINT arrives. SIGTERM is what
	// Kubernetes sends; SIGINT is Ctrl-C locally. Handling both means the local
	// and cluster shutdown paths are the same code.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("overture listening",
			"addr", srv.Addr, "version", version, "commit", commit)
		ready.Store(true)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		return gracefulShutdown(srv, logger)
	}
}

// gracefulShutdown implements the dance Kubernetes actually expects, which is
// less obvious than "handle SIGTERM and exit".
//
// When a pod is terminating, two things happen CONCURRENTLY and in no
// guaranteed order: the kubelet sends SIGTERM, and the endpoints controller
// removes the pod from its Service. Those propagate at different speeds — kube-
// proxy on every node has to update its rules. So for a short window after
// SIGTERM, traffic is still being routed here.
//
// Exiting immediately on SIGTERM drops those requests. That's the single most
// common cause of the handful of 502s that show up during every rolling update
// and get written off as "just a blip".
//
// So: fail readiness first (which is what actually starts the removal), pause
// long enough for that to propagate, and only then stop accepting connections
// and drain the ones in flight.
func gracefulShutdown(srv *http.Server, logger *slog.Logger) error {
	logger.Info("shutdown signal received; failing readiness first")

	// Step 1: report NotReady. The endpoints controller removes this pod from
	// the Service, and Traefik stops routing to it.
	ready.Store(false)

	// Step 2: keep serving while that propagates. The pod is still up and still
	// answering the requests that were already routed here.
	time.Sleep(2 * time.Second)

	// Step 3: stop accepting new connections and wait for in-flight ones.
	// Shutdown returns once they're done or the context expires.
	//
	// This must finish inside the pod's terminationGracePeriodSeconds (default
	// 30) or the kubelet sends SIGKILL and the drain is pointless.
	ctx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()

	logger.Info("draining in-flight requests", "grace", shutdownGrace)
	if err := srv.Shutdown(ctx); err != nil {
		return err
	}
	logger.Info("shutdown complete")
	return nil
}

func routes(reg *registry) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /", handleInfo)
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /readyz", handleReadyz)
	mux.Handle("GET /metrics", reg.handler())

	// Metrics wrap everything, including /metrics itself.
	return instrument(reg, mux)
}

// handleInfo is the thing a human hits to see what's running.
func handleInfo(w http.ResponseWriter, _ *http.Request) {
	host, err := os.Hostname()
	if err != nil {
		host = "unknown"
	}
	writeJSON(w, http.StatusOK, infoResponse{
		Name:      "overture",
		Version:   version,
		Commit:    commit,
		BuildDate: buildDate,
		Hostname:  host,
		Message:   "the ensemble is playing",
	})
}

// handleHealthz answers LIVENESS: "is this process wedged?"
//
// Failing it KILLS the container. So it checks one thing — that this goroutine
// can still be scheduled and reply. It deliberately does NOT check databases,
// caches, or any other dependency.
//
// Pointing liveness at a dependency is how a thirty-second database blip turns
// into every replica restarting at once, which turns a brief degradation into
// an outage. Dependency checks belong in readiness, where failing removes the
// pod from the Service and nothing gets killed.
func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReadyz answers READINESS: "should traffic be sent here?"
//
// Failing it removes the pod from the Service's endpoints. Recoverable, no
// restart. This is also the lever gracefulShutdown pulls to drain cleanly.
func handleReadyz(w http.ResponseWriter, _ *http.Request) {
	if !ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// statusRecorder captures the status code, because http.ResponseWriter doesn't
// expose what was written. Without this, every request would be recorded as 200.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func instrument(reg *registry, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(rec, req)

		// IMPORTANT: label with the ROUTE PATTERN, never the raw URL.
		//
		// Using req.URL.Path means every distinct URL becomes a new time series.
		// One /users/{id} endpoint with a million users is a million series, and
		// unbounded label cardinality is the standard way to take Prometheus
		// down. Routes here are fixed, so this is safe — but it is the habit
		// that matters.
		pattern := req.Pattern
		if pattern == "" {
			pattern = "unmatched"
		}
		reg.observe(req.Method, pattern, statusText(rec.status), time.Since(start))
	})
}

func statusText(code int) string {
	switch {
	case code >= 500:
		return "5xx"
	case code >= 400:
		return "4xx"
	case code >= 300:
		return "3xx"
	default:
		return "2xx"
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		slog.Error("encoding response failed", "err", err)
	}
}
