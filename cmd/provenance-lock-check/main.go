package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var digestRE = regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)
var zeroDigestRE = regexp.MustCompile(`^sha256:0{64}$`)

type entry map[string]string

type validator struct {
	repoRoot string
	strict   bool
	errors   []string
	warnings []string
}

func main() {
	var strict bool
	var repoRoot string
	flag.BoolVar(&strict, "strict", false, "enforce release-grade checks (no placeholders for required runtime dependencies)")
	flag.StringVar(&repoRoot, "repo-root", ".", "path to repository root")
	flag.Parse()

	rootAbs, err := filepath.Abs(repoRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolve repo-root: %v\n", err)
		os.Exit(2)
	}

	v := &validator{
		repoRoot: rootAbs,
		strict:   strict,
	}
	if err := v.run(); err != nil {
		fmt.Fprintf(os.Stderr, "provenance lock check failed: %v\n", err)
		os.Exit(1)
	}
}

func (v *validator) run() error {
	charts, err := parseSectionEntries(v.path("provenance/charts.lock.yaml"), "charts")
	if err != nil {
		return err
	}
	images, err := parseSectionEntries(v.path("provenance/images.lock.yaml"), "images")
	if err != nil {
		return err
	}
	crds, err := parseSectionEntries(v.path("provenance/crds.lock.yaml"), "crds")
	if err != nil {
		return err
	}
	deps, err := parseSectionEntries(v.path("provenance/licenses.lock.yaml"), "dependencies")
	if err != nil {
		return err
	}
	acceptedLicenses, err := parsePolicyAcceptedFamilies(v.path("provenance/licenses.lock.yaml"))
	if err != nil {
		return err
	}

	v.validateCharts(charts)
	v.validateImages(images)
	v.validateCRDs(crds)
	v.validateLicenses(deps, acceptedLicenses)

	mode := "development"
	if v.strict {
		mode = "strict"
	}
	fmt.Printf("Provenance lock check mode: %s\n", mode)
	fmt.Printf("  errors: %d\n", len(v.errors))
	fmt.Printf("  warnings: %d\n", len(v.warnings))

	if len(v.errors) > 0 {
		for _, msg := range v.errors {
			fmt.Printf("ERROR: %s\n", msg)
		}
		for _, msg := range v.warnings {
			fmt.Printf("WARN: %s\n", msg)
		}
		return errors.New("one or more blocking checks failed")
	}

	for _, msg := range v.warnings {
		fmt.Printf("WARN: %s\n", msg)
	}
	fmt.Println("Provenance lock check passed.")
	return nil
}

func (v *validator) path(rel string) string {
	return filepath.Join(v.repoRoot, rel)
}

func (v *validator) validateCharts(charts []entry) {
	for i, c := range charts {
		id := fmt.Sprintf("charts[%d] component=%q", i, c.get("component"))
		status := normalize(c.get("status"))
		deferred := status == "deferred"
		manifestInstall := normalize(c.get("install_method")) == "manifests"

		if c.get("component") == "" {
			v.addErr("%s missing component", id)
		}
		if !deferred && isPlaceholder(c.get("version")) {
			v.addErr("%s has unresolved version=%q", id, c.get("version"))
		}
		if !deferred && !manifestInstall {
			digest := c.get("chart_digest")
			if digest == "" {
				v.addErr("%s missing chart_digest", id)
			} else if isPlaceholder(digest) {
				if v.strict {
					v.addErr("%s unresolved chart_digest=%q", id, digest)
				} else {
					v.addWarn("%s unresolved chart_digest=%q", id, digest)
				}
			}
		}
		if v.strict && !deferred && normalize(c.get("pin_status")) != "pinned" {
			v.addErr("%s pin_status must be pinned (got %q)", id, c.get("pin_status"))
		}
	}
}

func (v *validator) validateImages(images []entry) {
	runtimeRequired := false

	for i, img := range images {
		id := fmt.Sprintf("images[%d] component=%q", i, img.get("component"))
		component := normalize(img.get("component"))
		status := normalize(img.get("status"))
		deferred := status == "deferred"
		localOnly := status == "local-only"
		required := parseBool(img.get("required"))
		digest := normalize(img.get("digest"))
		digestValid := isImmutableDigest(digest) && !isPlaceholderDigest(digest)

		if component == "epydios-control-plane-runtime" && required {
			runtimeRequired = true
		}

		if img.get("component") == "" {
			v.addErr("%s missing component", id)
		}
		if !deferred {
			if isPlaceholder(img.get("image")) {
				v.addErr("%s unresolved image=%q", id, img.get("image"))
			}
			if isPlaceholder(img.get("tag")) {
				v.addErr("%s unresolved tag=%q", id, img.get("tag"))
			}
		}
		if required && !deferred && !localOnly {
			if !digestValid {
				if v.strict {
					v.addErr("%s required runtime image missing immutable digest (got %q)", id, digest)
				} else {
					v.addWarn("%s required runtime image digest unresolved: %q", id, digest)
				}
			}
		}
		if status == "release-synced" && !required && !deferred && !localOnly && !digestValid {
			if v.strict {
				v.addErr("%s release-synced image must have non-placeholder immutable digest (got %q)", id, digest)
			} else {
				v.addWarn("%s release-synced image digest unresolved: %q", id, digest)
			}
		}
	}

	if v.strict && !runtimeRequired {
		v.addErr("images component=%q must remain release-required (required=true)", "epydios-control-plane-runtime")
	}
}

func (v *validator) validateCRDs(crds []entry) {
	for i, crd := range crds {
		id := fmt.Sprintf("crds[%d] component=%q", i, crd.get("component"))
		status := normalize(crd.get("status"))
		deferred := status == "deferred"
		ver := crd.get("version")
		ref := crd.get("release_or_ref")

		if crd.get("component") == "" {
			v.addErr("%s missing component", id)
		}
		if deferred {
			continue
		}
		if ver == "" && ref == "" {
			v.addErr("%s missing both version and release_or_ref", id)
		}
		verPlaceholder := isPlaceholder(ver)
		refPlaceholder := isPlaceholder(ref)
		if verPlaceholder && refPlaceholder {
			if v.strict {
				v.addErr("%s unresolved version/ref (version=%q release_or_ref=%q)", id, ver, ref)
			} else {
				v.addWarn("%s unresolved version/ref (version=%q release_or_ref=%q)", id, ver, ref)
			}
		}
	}
}

func (v *validator) validateLicenses(deps []entry, accepted map[string]struct{}) {
	for i, dep := range deps {
		id := fmt.Sprintf("licenses[%d] name=%q", i, dep.get("name"))
		if dep.get("name") == "" {
			v.addErr("%s missing name", id)
		}
		expected := dep.get("expected_license")
		if expected == "" {
			v.addErr("%s missing expected_license", id)
			continue
		}
		if _, ok := accepted[expected]; !ok {
			v.addErr("%s expected_license=%q not in policy.accepted_families", id, expected)
		}
		required := parseBool(dep.get("required"))
		status := normalize(dep.get("verification_status"))
		if required && status != "verified" {
			if v.strict {
				v.addErr("%s required dependency must be verified (got %q)", id, dep.get("verification_status"))
			} else {
				v.addWarn("%s required dependency license not yet verified (status=%q)", id, dep.get("verification_status"))
			}
		}
	}
}

func parsePolicyAcceptedFamilies(path string) (map[string]struct{}, error) {
	lines, err := readLines(path)
	if err != nil {
		return nil, err
	}

	inPolicy := false
	inAccepted := false
	policyIndent := -1
	acceptedIndent := -1
	families := map[string]struct{}{}

	for _, raw := range lines {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		indent := leadingSpaces(raw)

		if !inPolicy {
			if trimmed == "policy:" {
				inPolicy = true
				policyIndent = indent
			}
			continue
		}

		if indent <= policyIndent && strings.HasSuffix(trimmed, ":") {
			break
		}

		if !inAccepted {
			if trimmed == "accepted_families:" {
				inAccepted = true
				acceptedIndent = indent
			}
			continue
		}

		if indent <= acceptedIndent {
			inAccepted = false
			continue
		}

		if strings.HasPrefix(trimmed, "- ") {
			val := cleanValue(strings.TrimSpace(strings.TrimPrefix(trimmed, "- ")))
			if val != "" {
				families[val] = struct{}{}
			}
		}
	}

	if len(families) == 0 {
		return nil, fmt.Errorf("no accepted_families parsed from %s", path)
	}
	return families, nil
}

func parseSectionEntries(path, section string) ([]entry, error) {
	lines, err := readLines(path)
	if err != nil {
		return nil, err
	}

	var out []entry
	var current entry
	inSection := false
	sectionIndent := -1
	entryIndent := -1

	flush := func() {
		if current != nil {
			out = append(out, current)
			current = nil
		}
	}

	for _, raw := range lines {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		indent := leadingSpaces(raw)

		if !inSection {
			if trimmed == section+":" {
				inSection = true
				sectionIndent = indent
			}
			continue
		}

		if indent <= sectionIndent && strings.HasSuffix(trimmed, ":") {
			break
		}

		if strings.HasPrefix(trimmed, "- ") {
			if entryIndent == -1 || indent == entryIndent {
				flush()
				entryIndent = indent
				current = entry{}
				if k, v, ok := parseKeyValue(strings.TrimSpace(strings.TrimPrefix(trimmed, "- "))); ok {
					current[k] = v
				}
				continue
			}
			// Nested list item in the current object, not a new section entry.
			continue
		}

		if current == nil {
			continue
		}

		if k, v, ok := parseKeyValue(trimmed); ok {
			current[k] = v
		}
	}

	flush()
	if len(out) == 0 {
		return nil, fmt.Errorf("no entries parsed for section %q from %s", section, path)
	}
	return out, nil
}

func parseKeyValue(raw string) (string, string, bool) {
	idx := strings.Index(raw, ":")
	if idx <= 0 {
		return "", "", false
	}
	key := strings.TrimSpace(raw[:idx])
	val := cleanValue(raw[idx+1:])
	if key == "" {
		return "", "", false
	}
	return key, val, true
}

func cleanValue(v string) string {
	out := strings.TrimSpace(v)
	out = strings.Trim(out, "\"")
	out = strings.Trim(out, "'")
	return strings.TrimSpace(out)
}

func readLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan %s: %w", path, err)
	}
	return lines, nil
}

func leadingSpaces(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] != ' ' {
			return n
		}
		n++
	}
	return n
}

func parseBool(v string) bool {
	return normalize(v) == "true"
}

func normalize(in string) string {
	return strings.ToLower(strings.TrimSpace(in))
}

func isPlaceholder(in string) bool {
	v := normalize(in)
	if v == "" {
		return true
	}
	return v == "tbd" || strings.Contains(v, "tbd") || v == "n/a"
}

func isImmutableDigest(in string) bool {
	return digestRE.MatchString(normalize(in))
}

func isPlaceholderDigest(in string) bool {
	v := normalize(in)
	return isPlaceholder(v) || zeroDigestRE.MatchString(v)
}

func (e entry) get(key string) string {
	if e == nil {
		return ""
	}
	return cleanValue(e[key])
}

func (v *validator) addErr(format string, args ...any) {
	v.errors = append(v.errors, fmt.Sprintf(format, args...))
}

func (v *validator) addWarn(format string, args ...any) {
	v.warnings = append(v.warnings, fmt.Sprintf(format, args...))
}
