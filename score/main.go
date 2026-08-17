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
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
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

	// Whether a secret was delivered — never what it is.
	//
	// This is the observable half of layer 5. `backstage` SOPS-encrypts a token
	// into a public Git repository, ArgoCD decrypts it at sync time, and it
	// arrives here as an environment variable. Something has to prove that
	// chain worked, and the obvious way — echoing the value — would defeat the
	// entire exercise.
	//
	// So the app reports the FACT of delivery and gates a real endpoint on the
	// value. That is the general shape of the answer: prove a secret arrived by
	// demonstrating you can do something only its holder could, never by
	// showing it.
	TokenConfigured bool `json:"tokenConfigured"`
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	addr := defaultAddr
	if v := os.Getenv("OVERTURE_ADDR"); v != "" {
		addr = v
	}

	// Delivered by conductor from the SOPS-encrypted Secret in backstage/.
	// Empty is a valid state: the service still starts and still serves
	// everything else, and only the endpoint that needs the token refuses. A
	// service that won't boot without every optional secret is a service that
	// can't be debugged.
	token := os.Getenv("OVERTURE_API_TOKEN")

	reg := newRegistry()
	srv := &http.Server{
		Addr:              addr,
		Handler:           routes(reg, token),
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

func routes(reg *registry, token string) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /", handleInfo(token))
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /readyz", handleReadyz)
	mux.HandleFunc("GET /private", handlePrivate(token))
	mux.Handle("GET /metrics", reg.handler())

	// Metrics wrap everything, including /metrics itself.
	return instrument(reg, mux)
}

// handleInfo is the thing a human hits to see what's running.
func handleInfo(token string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		host, err := os.Hostname()
		if err != nil {
			host = "unknown"
		}
		writeJSON(w, http.StatusOK, infoResponse{
			Name:            "overture",
			Version:         version,
			Commit:          commit,
			BuildDate:       buildDate,
			Hostname:        host,
			Message:         "the ensemble is playing",
			TokenConfigured: token != "",
		})
	}
}

// handlePrivate gates an endpoint on the secret from `backstage`.
//
// It exists so layer 5 is a demonstration rather than a ceremony. Encrypting a
// value nothing reads proves only that the encryption command ran; being able
// to authenticate with it proves the whole chain — SOPS in Git, decryption at
// sync, delivery into the pod — actually worked.
func handlePrivate(token string) http.HandlerFunc {
	const prefix = "Bearer "

	return func(w http.ResponseWriter, r *http.Request) {
		// No token delivered. 503 rather than 401, because the distinction
		// matters when debugging: 401 means "your credential is wrong", 503
		// means "this service has no credential to check against". Collapsing
		// them sends you looking at the client when the problem is the
		// deployment.
		if token == "" {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"error": "no token configured; is the backstage secret mounted?",
			})
			return
		}

		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, prefix) {
			w.Header().Set("WWW-Authenticate", `Bearer realm="overture"`)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "bearer token required"})
			return
		}

		// Compare hashes, in constant time. Two separate properties:
		//
		//   crypto/subtle avoids the early return that == compiles to, so the
		//   time taken doesn't reveal how many leading bytes were correct.
		//   Without it an attacker can recover a token byte by byte from
		//   timing alone.
		//
		//   Hashing first makes the comparison length-independent.
		//   ConstantTimeCompare returns 0 immediately for differing lengths,
		//   which leaks the token's length — a small leak, and free to close,
		//   since SHA-256 output is always 32 bytes.
		got := sha256.Sum256([]byte(strings.TrimPrefix(header, prefix)))
		want := sha256.Sum256([]byte(token))
		if subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
			w.Header().Set("WWW-Authenticate", `Bearer realm="overture"`)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid token"})
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{
			"message": "authenticated — the backstage secret made it all the way here",
		})
	}
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

// Unwrap is how http.ResponseController reaches the real ResponseWriter
// underneath this one. Without it, wrapping quietly strips every optional
// capability the server provides — Flush, Hijack, SetWriteDeadline — from any
// handler added later, because a type assertion against *statusRecorder fails
// even though the writer beneath it would have satisfied it.
//
// Nothing here streams today, which is exactly why this is worth one line now:
// the failure mode is a handler that works standalone and silently buffers
// forever once it's behind the middleware.
func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func instrument(reg *registry, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		// Set on every response, including /metrics, before the handler can
		// write. Both content types this service emits are unambiguous — but
		// MIME sniffing is how a reflected value inside a JSON error body gets
		// rendered as HTML by a browser, and the fix costs one header set once
		// rather than vigilance in every handler.
		rec.Header().Set("X-Content-Type-Options", "nosniff")

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
