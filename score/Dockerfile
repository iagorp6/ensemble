# syntax=docker/dockerfile:1
# =============================================================================
# score / Dockerfile — building overture for an architecture we aren't on
# =============================================================================
#
# THE PROBLEM THIS FILE SOLVES
#
# Layer 1 provisions an Ampere A1 instance, which is aarch64. GitHub's hosted
# runners are x86_64. So every image this pipeline produces has to be built for
# a machine the builder isn't.
#
# There are two ways to do that, and the difference is not small.
#
#   EMULATION — register QEMU with binfmt_misc, then run the entire build stage
#   under emulated aarch64. It works and it is what most tutorials show. It is
#   also 10-20x slower, because every instruction of the compiler is being
#   interpreted. A Go build that takes 20 seconds natively takes several
#   minutes; anything doing native compilation takes long enough to hit job
#   timeouts.
#
#   CROSS-COMPILATION — run the build stage NATIVELY on the runner's own
#   architecture, and tell the compiler to emit code for the target. Go does
#   this with two environment variables and no toolchain gymnastics, because
#   the standard library ships precompiled for every supported platform.
#
# `--platform=$BUILDPLATFORM` on the FROM line below is what selects the second
# option. It pins the build stage to the BUILDER's architecture rather than the
# target's. Without it, BuildKit would helpfully run this stage as aarch64 —
# under QEMU — and the build would still succeed, just very slowly. That is why
# the mistake is easy to miss: it isn't an error, it's a bill.
#
# The final stage needs no emulation either. Nothing executes in it — the arm64
# base image is pulled and a file is copied in. So this pipeline never installs
# QEMU at all, which is worth noticing in score.yml where the usual
# `docker/setup-qemu-action` step is deliberately absent.
#
# This is the single biggest reason overture is written in Go. A Python or Node
# service would need its dependencies installed for the target architecture,
# which means either emulation or a cross-build toolchain, and the pipeline gets
# meaningfully harder.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — build (runs natively, emits for the target)
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build

# Supplied automatically by BuildKit, one set per --platform entry.
ARG TARGETOS
ARG TARGETARCH

# Supplied by the workflow so the binary can report what produced it.
ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown

WORKDIR /src

# go.mod alone, before the source. Docker caches layers, so as long as
# dependencies haven't changed this layer is reused and a source-only edit skips
# straight to compiling. With zero dependencies there is nothing to download
# here — but the layout is the habit worth keeping.
COPY go.mod ./
RUN go mod download

COPY *.go ./

# -trimpath strips absolute build paths from the binary. Two things follow:
# reproducibility (the same source produces the same bytes regardless of where
# it was built) and not leaking a directory layout into a published artifact.
#
# -s -w drop the symbol table and DWARF debug info, taking roughly 30% off the
# binary. The tradeoff is that a core dump is harder to read — acceptable for a
# service whose debugging story is structured logs and metrics.
#
# -X injects values into package-level string variables at link time, which is
# how version/commit/date get stamped in. See the vars in main.go.
#
# CGO_ENABLED=0 is what makes this a genuinely static binary — no libc, nothing
# to resolve at runtime. That is what lets the final image be distroless.
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT} -X main.buildDate=${BUILD_DATE}" \
      -o /out/overture .

# -----------------------------------------------------------------------------
# Stage 2 — runtime
# -----------------------------------------------------------------------------
#
# distroless/static contains a CA bundle, /etc/passwd, timezone data, and
# nothing else. No shell, no package manager, no coreutils. An attacker who
# achieves code execution in this container finds no tools to pivot with.
#
# WHY THIS IS PINNED BY TAG AND NOT BY DIGEST, when conductor's deployment
# manifest pins the app image by digest — the two are pinned differently on
# purpose:
#
#   The APP image must be byte-identical for a rollback to mean anything, so it
#   is referenced by digest in the manifest. Immutability is the whole point.
#
#   The BASE image should absorb security patches. Pinning it by digest freezes
#   it, and without something like Renovate opening update PRs, "pinned" quietly
#   becomes "unpatched forever". A floating :nonroot tag means every rebuild
#   picks up base fixes.
#
# Different artifacts, opposite requirements. Adding Renovate — noted in the
# root README's "what I'd add next" — is what would let this be pinned too.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/overture /usr/local/bin/overture

# 65532 is distroless's `nonroot` user. It matches runAsUser in
# conductor/manifests/overture/deployment.yaml, which matters because that
# namespace enforces the `restricted` Pod Security Standard — a container that
# cannot prove it runs as non-root is rejected at admission.
#
# Numeric rather than `USER nonroot`: Kubernetes' runAsNonRoot check reads the
# image's user as a number and cannot resolve a name against /etc/passwd.
USER 65532:65532

EXPOSE 9898

ENTRYPOINT ["/usr/local/bin/overture"]
