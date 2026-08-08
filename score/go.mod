// No `require` block, and no go.sum, because this module has ZERO external
// dependencies. Everything below is Go's standard library.
//
// That's a deliberate choice for a demo service, and it buys three things:
//
//   - Nothing to audit. The conversation about where third-party code comes
//     from doesn't happen, because there isn't any.
//   - The container build needs no module download, so it works offline and
//     can't be broken by a proxy outage or a yanked version.
//   - The Prometheus exposition format gets written out by hand in metrics.go,
//     which means it has to be understood rather than imported. It's a text
//     format; it fits on a page.
//
// A real service would pull in prometheus/client_golang and be right to.
module github.com/iagorp6/ensemble/score

go 1.26
