package main

import (
	"os"
	"path/filepath"
	"strings"
)

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
// or below root (also normalised). The prefix test carries a
// separator boundary, so a sibling like "ember2" never matches
// the root "ember".
func underRoot(clean, root string) bool {
	if clean == root {
		return true
	}
	return strings.HasPrefix(clean, strings.TrimSuffix(root, "/")+"/")
}

// canonicalPath returns the confinement-comparison form of p:
// separators normalised to "/", "." and ".." segments resolved
// lexically (a ".." can never pop above the path's anchor), and
// — where the path exists on this machine — symlinks resolved
// via filepath.EvalSymlinks on the deepest existing ancestor,
// so a symlink or junction inside a root that points outside it
// resolves to its real target and fails the prefix test. Case
// is folded (Windows paths are case-insensitive; folding both
// sides keeps the Linux test runs consistent). A path that does
// not exist falls back to its lexical form: ".." is still
// resolved, and a file that does not exist cannot be launched
// anyway — but it is never waved through on a string prefix.
func canonicalPath(p string) string {
	lexical := resolveDots(strings.ReplaceAll(strings.TrimSpace(p), "\\", "/"))
	if resolved := evalExisting(lexical); resolved != "" {
		return strings.ToLower(resolveDots(strings.ReplaceAll(resolved, "\\", "/")))
	}
	return strings.ToLower(lexical)
}

// resolveDots collapses duplicate separators and "." segments
// and resolves ".." by popping the previous segment. The anchor
// (a leading "/" or a drive segment like "c:") is never popped.
func resolveDots(p string) string {
	rooted := strings.HasPrefix(p, "/")
	parts := strings.Split(p, "/")
	out := make([]string, 0, len(parts))
	for _, seg := range parts {
		switch seg {
		case "", ".":
		case "..":
			if len(out) > 0 && !strings.HasSuffix(out[len(out)-1], ":") {
				out = out[:len(out)-1]
			}
		default:
			out = append(out, seg)
		}
	}
	s := strings.Join(out, "/")
	if rooted {
		s = "/" + s
	}
	return s
}

// evalExisting resolves symlinks for the deepest ancestor of
// lexical that exists on this machine and re-appends the
// remaining tail. It returns "" when lexical is not a native
// absolute path (e.g. a Windows path in a Linux test run), in
// which case the caller uses the lexical form.
func evalExisting(lexical string) string {
	native := filepath.FromSlash(lexical)
	if !filepath.IsAbs(native) {
		return ""
	}
	rest := ""
	for cur := native; ; {
		if _, err := os.Lstat(cur); err == nil {
			resolved, err := filepath.EvalSymlinks(cur)
			if err != nil {
				return ""
			}
			if rest == "" {
				return resolved
			}
			return filepath.Join(resolved, rest)
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return ""
		}
		rest = filepath.Join(filepath.Base(cur), rest)
		cur = parent
	}
}
