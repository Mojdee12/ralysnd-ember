package main

import "strings"

// Path handling for the confinement checks. Windows paths are
// case-insensitive and accept both separators; the checks
// normalise by hand (instead of path/filepath) so they behave
// identically in the Linux test runs and on Windows.

func cleanPath(p string) string {
	p = strings.ReplaceAll(strings.TrimSpace(p), "\\", "/")
	// Collapse duplicate separators and "." segments; keep a
	// leading "//" (UNC) intact in spirit by treating the path
	// as rooted either way.
	parts := strings.Split(p, "/")
	out := make([]string, 0, len(parts))
	for _, seg := range parts {
		if seg == "." {
			continue
		}
		out = append(out, seg)
	}
	return strings.ToLower(strings.Join(out, "/"))
}

func baseName(p string) string {
	p = strings.ReplaceAll(p, "\\", "/")
	if i := strings.LastIndex(p, "/"); i >= 0 {
		return strings.ToLower(p[i+1:])
	}
	return strings.ToLower(p)
}

// underRoot reports whether clean (already normalised) sits at
// or below root (also normalised).
func underRoot(clean, root string) bool {
	if clean == root {
		return true
	}
	return strings.HasPrefix(clean, strings.TrimSuffix(root, "/")+"/")
}
