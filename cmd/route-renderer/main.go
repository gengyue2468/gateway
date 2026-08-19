package main

import (
	"errors"
	"flag"
	"fmt"
	"html"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	defaultConfig       = "/config/routes.yaml"
	defaultEdgeOutput   = "/generated/edge.Caddyfile"
	defaultOriginOutput = "/generated/origin.caddy"

	defaultCacheTTL                 = "4h"
	defaultCacheStale               = "0s"
	defaultCacheControl             = "public, max-age=14400"
	defaultCacheMaxBodyBytes uint64 = 1048576
)

type Config struct {
	Version int     `yaml:"version"`
	Ingress []Route `yaml:"ingress"`
}

type Route struct {
	Hostname     string        `yaml:"hostname,omitempty"`
	Path         string        `yaml:"path,omitempty"`
	Methods      []string      `yaml:"methods,omitempty"`
	Service      ServiceList   `yaml:"service,omitempty"`
	Redirect     string        `yaml:"redirect,omitempty"`
	Rewrite      string        `yaml:"rewrite,omitempty"`
	MetaRedirect string        `yaml:"meta_redirect,omitempty"`
	BypassAnubis bool          `yaml:"bypass_anubis,omitempty"`
	Cache        *CacheConfig  `yaml:"cache,omitempty"`
	LoadBalance  string        `yaml:"load_balance,omitempty"`
	Health       *HealthConfig `yaml:"health,omitempty"`
	RateLimit    *RateLimit    `yaml:"rate_limit,omitempty"`
}

// CacheConfig accepts the historical boolean shorthand as well as route-level
// cache policy. The object form is an explicit opt-in unless enabled is false.
type CacheConfig struct {
	Enabled               *bool   `yaml:"enabled,omitempty"`
	TTL                   string  `yaml:"ttl,omitempty"`
	Stale                 string  `yaml:"stale,omitempty"`
	DefaultCacheControl   string  `yaml:"default_cache_control,omitempty"`
	MaxCacheableBodyBytes *uint64 `yaml:"max_cacheable_body_bytes,omitempty"`
	SortQuery             *bool   `yaml:"sort_query,omitempty"`
}

var cacheConfigFields = map[string]struct{}{
	"enabled":                  {},
	"ttl":                      {},
	"stale":                    {},
	"default_cache_control":    {},
	"max_cacheable_body_bytes": {},
	"sort_query":               {},
}

func (c *CacheConfig) UnmarshalYAML(node *yaml.Node) error {
	if node.Kind == yaml.ScalarNode {
		if node.Tag != "!!bool" {
			return errors.New("cache must be a boolean or an object")
		}
		var enabled bool
		if err := node.Decode(&enabled); err != nil {
			return fmt.Errorf("decode cache: %w", err)
		}
		*c = CacheConfig{Enabled: &enabled}
		return nil
	}
	if node.Kind != yaml.MappingNode {
		return errors.New("cache must be a boolean or an object")
	}
	for index := 0; index < len(node.Content); index += 2 {
		key := node.Content[index]
		if key.Kind != yaml.ScalarNode || key.Tag != "!!str" {
			return errors.New("cache object keys must be strings")
		}
		if _, ok := cacheConfigFields[key.Value]; !ok {
			return fmt.Errorf("cache contains unknown field %q", key.Value)
		}
	}
	type plainCacheConfig CacheConfig
	var value plainCacheConfig
	if err := node.Decode(&value); err != nil {
		return fmt.Errorf("decode cache: %w", err)
	}
	*c = CacheConfig(value)
	return nil
}

type normalizedCache struct {
	TTL                   string
	Stale                 string
	DefaultCacheControl   string
	MaxCacheableBodyBytes uint64
}

type ServiceList []string

func (s *ServiceList) UnmarshalYAML(node *yaml.Node) error {
	switch node.Kind {
	case yaml.ScalarNode:
		if node.Tag != "!!str" {
			return errors.New("service must be a string or a list of strings")
		}
		*s = ServiceList{node.Value}
		return nil
	case yaml.SequenceNode:
		values := make(ServiceList, 0, len(node.Content))
		for _, item := range node.Content {
			if item.Kind != yaml.ScalarNode || item.Tag != "!!str" {
				return errors.New("service list entries must be strings")
			}
			values = append(values, item.Value)
		}
		*s = values
		return nil
	default:
		return errors.New("service must be a string or a list of strings")
	}
}

type HealthConfig struct {
	Active      *bool  `yaml:"active,omitempty"`
	URI         string `yaml:"uri,omitempty"`
	Interval    string `yaml:"interval,omitempty"`
	Timeout     string `yaml:"timeout,omitempty"`
	TryDuration string `yaml:"try_duration,omitempty"`
}

type normalizedHealth struct {
	Active      bool
	URI         string
	Interval    string
	Timeout     string
	TryDuration string
}

type RateLimit struct {
	Name       string   `yaml:"name"`
	Key        string   `yaml:"key,omitempty"`
	Window     string   `yaml:"window"`
	Events     int      `yaml:"events"`
	Methods    []string `yaml:"methods,omitempty"`
	IPv4Prefix int      `yaml:"ipv4_prefix,omitempty"`
	IPv6Prefix int      `yaml:"ipv6_prefix,omitempty"`
}

var hostnamePattern = regexp.MustCompile(`^(\*\.)?[A-Za-z0-9][A-Za-z0-9._:-]*$`)
var acmeOverrideDomainPattern = regexp.MustCompile(`^(?:_acme-challenge\.)?(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.?$`)
var rateLimitKeyPattern = regexp.MustCompile(`^\{(?:remote_host|http\.request\.remote\.host)\}$`)
var rateLimitNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

func main() {
	configPath := flag.String("config", defaultConfig, "route YAML path")
	edgeOutput := flag.String("edge-output", defaultEdgeOutput, "generated edge Caddyfile path")
	originOutput := flag.String("origin-output", defaultOriginOutput, "generated origin Caddyfile path")
	checkOnly := flag.Bool("check", false, "validate without writing generated files")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		fatal(err)
	}
	acmeOverrideDomain, err := loadACMEOverrideDomain()
	if err != nil {
		fatal(err)
	}

	if *checkOnly {
		return
	}

	if err := writeAtomically(*edgeOutput, renderEdge(cfg, acmeOverrideDomain)); err != nil {
		fatal(fmt.Errorf("write edge config: %w", err))
	}
	if err := writeAtomically(*originOutput, renderOrigin(cfg)); err != nil {
		fatal(fmt.Errorf("write origin config: %w", err))
	}
}

func loadACMEOverrideDomain() (string, error) {
	value := strings.TrimSpace(os.Getenv("ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN"))
	if value == "" {
		return "", nil
	}
	if !acmeOverrideDomainPattern.MatchString(value) {
		return "", fmt.Errorf("ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN must be a DNS name, optionally prefixed with _acme-challenge, got %q", value)
	}
	return value, nil
}

func loadConfig(path string) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, fmt.Errorf("open config %q: %w", path, err)
	}
	defer file.Close()

	var cfg Config
	decoder := yaml.NewDecoder(file)
	decoder.KnownFields(true)
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return Config{}, errors.New("config must contain exactly one YAML document")
		}
		return Config{}, fmt.Errorf("parse trailing YAML: %w", err)
	}

	if err := validateConfig(cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func validateConfig(cfg Config) error {
	if cfg.Version != 1 {
		return fmt.Errorf("version must be 1, got %d", cfg.Version)
	}
	if len(cfg.Ingress) < 1 {
		return errors.New("ingress must contain the final http_status:444 catch-all")
	}

	hosts := 0
	seen := make(map[string]struct{})
	for index, route := range cfg.Ingress {
		if err := validateRoute(index, route, index == len(cfg.Ingress)-1); err != nil {
			return err
		}
		if route.Hostname != "" {
			hosts++
		}
		if route.isCatchAll() {
			if index != len(cfg.Ingress)-1 {
				return fmt.Errorf("ingress rule %d is catch-all but is not last", index+1)
			}
			continue
		}
		key := route.Hostname + "\x00" + route.Path
		if _, ok := seen[key]; ok {
			return fmt.Errorf("ingress rule %d duplicates hostname/path from an earlier rule", index+1)
		}
		seen[key] = struct{}{}
	}
	if !cfg.Ingress[len(cfg.Ingress)-1].isCatchAll() {
		return errors.New("final ingress rule must be exactly: service: http_status:444")
	}
	return nil
}

func validateRoute(index int, route Route, isLast bool) error {
	prefix := fmt.Sprintf("ingress rule %d", index+1)
	if hasUnsafeText(route.Hostname) || hasUnsafeText(route.Path) {
		return fmt.Errorf("%s contains a forbidden newline, backtick, or quote", prefix)
	}
	if route.Hostname != "" {
		if !hostnamePattern.MatchString(route.Hostname) {
			return fmt.Errorf("%s has invalid hostname %q", prefix, route.Hostname)
		}
		if strings.Contains(route.Hostname, "*") && !strings.HasPrefix(route.Hostname, "*.") {
			return fmt.Errorf("%s wildcard must be a leading *.example.com", prefix)
		}
	}
	if route.Path != "" {
		if _, err := regexp.Compile(route.Path); err != nil {
			return fmt.Errorf("%s has invalid path regexp: %w", prefix, err)
		}
	}
	if err := validateHTTPMethods(prefix, "methods", route.Methods); err != nil {
		return err
	}
	if route.isCatchAllService() && !route.isCatchAll() {
		return fmt.Errorf("%s catch-all cannot have route options", prefix)
	}
	if route.Hostname == "" && route.Path == "" && !route.isCatchAll() {
		return fmt.Errorf("%s must declare hostname or path", prefix)
	}
	if route.isCatchAll() {
		if !isLast {
			return fmt.Errorf("%s catch-all must be the final rule", prefix)
		}
		if len(route.Methods) > 0 || route.Cache != nil || route.LoadBalance != "" || route.Health != nil || route.BypassAnubis {
			return fmt.Errorf("%s catch-all cannot have route options", prefix)
		}
		return nil
	}

	terminalActions := 0
	if route.Redirect != "" {
		terminalActions++
	}
	if route.MetaRedirect != "" {
		terminalActions++
	}
	if terminalActions > 1 {
		return fmt.Errorf("%s may define only one of redirect or meta_redirect", prefix)
	}
	if route.Rewrite != "" && terminalActions > 0 {
		return fmt.Errorf("%s rewrite cannot be combined with redirect or meta_redirect", prefix)
	}
	if route.Redirect != "" {
		if err := validateRedirectTarget(route.Redirect); err != nil {
			return fmt.Errorf("%s redirect: %w", prefix, err)
		}
		if len(route.Service) != 0 || route.Cache != nil || route.LoadBalance != "" || route.Health != nil || route.BypassAnubis || route.RateLimit != nil {
			return fmt.Errorf("%s redirect cannot have service or route options", prefix)
		}
		return nil
	}
	if route.MetaRedirect != "" {
		if err := validateRedirectTarget(route.MetaRedirect); err != nil {
			return fmt.Errorf("%s meta_redirect: %w", prefix, err)
		}
		if len(route.Service) != 0 || route.Cache != nil || route.LoadBalance != "" || route.Health != nil || route.BypassAnubis || route.RateLimit != nil {
			return fmt.Errorf("%s meta_redirect cannot have service or route options", prefix)
		}
		return nil
	}
	if len(route.Service) == 0 {
		return fmt.Errorf("%s service must not be empty unless it is a redirect or meta_redirect", prefix)
	}
	if route.Cache != nil {
		if err := validateCacheConfig(prefix, *route.Cache); err != nil {
			return err
		}
	}
	if route.Rewrite != "" {
		if err := validateRewriteTarget(route.Rewrite); err != nil {
			return fmt.Errorf("%s rewrite: %w", prefix, err)
		}
	}
	if route.BypassAnubis && route.Path == "" {
		return fmt.Errorf("%s bypass_anubis requires a path regexp", prefix)
	}
	if route.BypassAnubis && route.Hostname == "" {
		return fmt.Errorf("%s bypass_anubis requires a hostname for an edge route", prefix)
	}
	if route.BypassAnubis && route.cacheEnabled() {
		return fmt.Errorf("%s bypass_anubis routes must set cache: false", prefix)
	}
	if route.RateLimit != nil {
		if !route.BypassAnubis && route.Hostname == "" {
			return fmt.Errorf("%s rate_limit requires hostname for an edge route", prefix)
		}
		if !rateLimitNamePattern.MatchString(route.RateLimit.Name) {
			return fmt.Errorf("%s rate_limit.name must contain only letters, digits, underscores, or hyphens", prefix)
		}
		key := route.RateLimit.Key
		if key == "" {
			key = "{remote_host}"
		}
		if !rateLimitKeyPattern.MatchString(key) {
			return fmt.Errorf("%s rate_limit.key must be {remote_host} or {http.request.remote.host}", prefix)
		}
		if _, err := time.ParseDuration(route.RateLimit.Window); err != nil {
			return fmt.Errorf("%s has invalid rate_limit.window: %w", prefix, err)
		}
		if route.RateLimit.Events < 1 {
			return fmt.Errorf("%s rate_limit.events must be positive", prefix)
		}
		if err := validateHTTPMethods(prefix, "rate_limit.methods", route.RateLimit.Methods); err != nil {
			return err
		}
		if route.RateLimit.IPv4Prefix < 0 || route.RateLimit.IPv4Prefix > 32 {
			return fmt.Errorf("%s rate_limit.ipv4_prefix must be between 0 and 32", prefix)
		}
		if route.RateLimit.IPv6Prefix < 0 || route.RateLimit.IPv6Prefix > 128 {
			return fmt.Errorf("%s rate_limit.ipv6_prefix must be between 0 and 128", prefix)
		}
	}
	serviceScheme := ""
	seenServices := make(map[string]struct{})
	for _, service := range route.Service {
		if err := validateService(service); err != nil {
			return fmt.Errorf("%s: %w", prefix, err)
		}
		if _, ok := seenServices[service]; ok {
			return fmt.Errorf("%s repeats service upstream %q", prefix, service)
		}
		seenServices[service] = struct{}{}
		scheme := strings.SplitN(service, "://", 2)[0]
		if serviceScheme == "" {
			serviceScheme = scheme
		} else if serviceScheme != scheme {
			return fmt.Errorf("%s mixes upstream URL schemes; use the same scheme for all service entries", prefix)
		}
	}
	if route.LoadBalance != "" && !validLoadBalancers[route.LoadBalance] {
		return fmt.Errorf("%s has unsupported load_balance %q", prefix, route.LoadBalance)
	}
	if len(route.Service) == 1 && route.LoadBalance != "" {
		return fmt.Errorf("%s load_balance requires multiple service upstreams", prefix)
	}
	if route.Health != nil {
		if route.Health.URI != "" && (!strings.HasPrefix(route.Health.URI, "/") || hasUnsafeText(route.Health.URI)) {
			return fmt.Errorf("%s health.uri must be a safe absolute path", prefix)
		}
		for name, value := range map[string]string{
			"health.interval":     route.Health.Interval,
			"health.timeout":      route.Health.Timeout,
			"health.try_duration": route.Health.TryDuration,
		} {
			if value != "" {
				if _, err := time.ParseDuration(value); err != nil {
					return fmt.Errorf("%s has invalid %s: %w", prefix, name, err)
				}
			}
		}
	}
	return nil
}

func validateCacheConfig(prefix string, cache CacheConfig) error {
	if cache.Enabled != nil && !*cache.Enabled {
		if cache.TTL != "" || cache.Stale != "" || cache.DefaultCacheControl != "" || cache.MaxCacheableBodyBytes != nil || (cache.SortQuery != nil && *cache.SortQuery) {
			return fmt.Errorf("%s disabled cache cannot define cache policy", prefix)
		}
		return nil
	}
	if cache.TTL != "" {
		ttl, err := time.ParseDuration(cache.TTL)
		if err != nil || ttl <= 0 {
			if err == nil {
				err = errors.New("must be greater than zero")
			}
			return fmt.Errorf("%s has invalid cache.ttl: %w", prefix, err)
		}
	}
	if cache.Stale != "" {
		stale, err := time.ParseDuration(cache.Stale)
		if err != nil || stale < 0 {
			if err == nil {
				err = errors.New("must not be negative")
			}
			return fmt.Errorf("%s has invalid cache.stale: %w", prefix, err)
		}
	}
	if cache.DefaultCacheControl != "" {
		if strings.TrimSpace(cache.DefaultCacheControl) == "" || hasUnsafeText(cache.DefaultCacheControl) {
			return fmt.Errorf("%s cache.default_cache_control must be non-empty and free of Caddy control characters", prefix)
		}
	}
	if cache.MaxCacheableBodyBytes != nil && *cache.MaxCacheableBodyBytes == 0 {
		return fmt.Errorf("%s cache.max_cacheable_body_bytes must be positive", prefix)
	}
	if cache.SortQuery != nil && *cache.SortQuery {
		return fmt.Errorf("%s cache.sort_query=true is unsupported by cache-handler v0.16.0; no query-normalizing Caddy directive was rendered", prefix)
	}
	return nil
}

var validLoadBalancers = map[string]bool{
	"random":         true,
	"first":          true,
	"round_robin":    true,
	"least_conn":     true,
	"ip_hash":        true,
	"client_ip_hash": true,
	"uri_hash":       true,
}

var validRateLimitMethods = map[string]bool{
	"GET":     true,
	"HEAD":    true,
	"POST":    true,
	"PUT":     true,
	"PATCH":   true,
	"DELETE":  true,
	"OPTIONS": true,
	"CONNECT": true,
	"TRACE":   true,
}

func validateHTTPMethods(prefix string, field string, methods []string) error {
	seen := make(map[string]struct{}, len(methods))
	for _, method := range methods {
		if !validRateLimitMethods[method] {
			return fmt.Errorf("%s has unsupported %s value %q", prefix, field, method)
		}
		if _, ok := seen[method]; ok {
			return fmt.Errorf("%s repeats %s value %q", prefix, field, method)
		}
		seen[method] = struct{}{}
	}
	return nil
}

func validateService(service string) error {
	if service == "http_status:444" {
		return errors.New("http_status:444 is only valid as the final catch-all")
	}
	if hasUnsafeText(service) {
		return fmt.Errorf("service %q contains a forbidden newline, backtick, or quote", service)
	}
	parsed, err := url.Parse(service)
	if err != nil || parsed.Host == "" || parsed.User != nil {
		return fmt.Errorf("service %q must be an http://, https://, or h2c:// URL without credentials", service)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" && parsed.Scheme != "h2c" {
		return fmt.Errorf("service %q has unsupported URL scheme", service)
	}
	if parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf("service %q must not contain a path, query, or fragment", service)
	}
	return nil
}

func validateRedirectTarget(target string) error {
	if target == "" || hasUnsafeTargetText(target) {
		return errors.New("target must be a non-empty URL or absolute path without whitespace or Caddyfile control characters")
	}
	if !balancedPlaceholders(target) {
		return errors.New("target has unbalanced Caddy placeholders")
	}
	if strings.HasPrefix(target, "/") {
		if strings.HasPrefix(target, "//") {
			return errors.New("protocol-relative targets are not allowed")
		}
		return nil
	}

	base := target
	if marker := strings.IndexByte(base, '{'); marker >= 0 {
		base = base[:marker]
	}
	parsed, err := url.Parse(base)
	if err != nil || parsed.Host == "" || parsed.User != nil {
		return errors.New("target must be an absolute http(s) URL or an absolute path")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return errors.New("target URL must use http or https")
	}
	return nil
}

func validateRewriteTarget(target string) error {
	if target == "" || hasUnsafeTargetText(target) || !strings.HasPrefix(target, "/") || strings.HasPrefix(target, "//") {
		return errors.New("target must be an absolute path without whitespace or Caddyfile control characters")
	}
	if !balancedPlaceholders(target) {
		return errors.New("target has unbalanced Caddy placeholders")
	}
	return nil
}

func hasUnsafeTargetText(value string) bool {
	return strings.ContainsAny(value, " \t\r\n`\\\"")
}

func balancedPlaceholders(value string) bool {
	return strings.Count(value, "{") == strings.Count(value, "}")
}

func (r Route) isCatchAllService() bool {
	return r.Hostname == "" && r.Path == "" && len(r.Service) == 1 && r.Service[0] == "http_status:444"
}

func (r Route) isCatchAll() bool {
	return r.isCatchAllService() &&
		len(r.Methods) == 0 &&
		r.Redirect == "" &&
		r.Rewrite == "" &&
		r.MetaRedirect == "" &&
		!r.BypassAnubis &&
		r.Cache == nil &&
		r.LoadBalance == "" &&
		r.Health == nil &&
		r.RateLimit == nil
}

func (r Route) cacheEnabled() bool {
	if r.Cache == nil {
		return false
	}
	return r.Cache.Enabled == nil || *r.Cache.Enabled
}

func (r Route) cachePolicy() normalizedCache {
	result := normalizedCache{
		TTL:                   defaultCacheTTL,
		Stale:                 defaultCacheStale,
		DefaultCacheControl:   defaultCacheControl,
		MaxCacheableBodyBytes: defaultCacheMaxBodyBytes,
	}
	if r.Cache == nil {
		return result
	}
	if r.Cache.TTL != "" {
		result.TTL = r.Cache.TTL
	}
	if r.Cache.Stale != "" {
		result.Stale = r.Cache.Stale
	}
	if r.Cache.DefaultCacheControl != "" {
		result.DefaultCacheControl = r.Cache.DefaultCacheControl
	}
	if r.Cache.MaxCacheableBodyBytes != nil {
		result.MaxCacheableBodyBytes = *r.Cache.MaxCacheableBodyBytes
	}
	return result
}

func (r Route) health() normalizedHealth {
	result := normalizedHealth{
		Active:      true,
		URI:         "/healthz",
		Interval:    "30s",
		Timeout:     "5s",
		TryDuration: "5s",
	}
	if r.Health == nil {
		return result
	}
	if r.Health.Active != nil {
		result.Active = *r.Health.Active
	}
	if r.Health.URI != "" {
		result.URI = r.Health.URI
	}
	if r.Health.Interval != "" {
		result.Interval = r.Health.Interval
	}
	if r.Health.Timeout != "" {
		result.Timeout = r.Health.Timeout
	}
	if r.Health.TryDuration != "" {
		result.TryDuration = r.Health.TryDuration
	}
	return result
}

func renderEdge(cfg Config, acmeOverrideDomain string) string {
	hosts := make([]string, 0, len(cfg.Ingress))
	seen := make(map[string]struct{})
	for _, route := range cfg.Ingress {
		if route.Hostname == "" {
			continue
		}
		if _, ok := seen[route.Hostname]; ok {
			continue
		}
		seen[route.Hostname] = struct{}{}
		hosts = append(hosts, route.Hostname)
	}

	var b strings.Builder
	b.WriteString("{\n")
	b.WriteString("    admin 127.0.0.1:2019\n")
	b.WriteString("    order coraza_waf first\n")
	b.WriteString("    email {$ACME_EMAIL}\n\n")
	b.WriteString("    servers :443 {\n")
	b.WriteString("        protocols h1 h2 h3\n")
	b.WriteString("        0rtt off\n")
	b.WriteString("        timeouts {\n")
	b.WriteString("            read_header 10s\n")
	b.WriteString("        }\n")
	b.WriteString("    }\n")
	b.WriteString("}\n\n")
	renderHTTPCatchAll(&b, hosts)
	if len(hosts) == 0 {
		return b.String()
	}
	fmt.Fprintf(&b, "%s {\n", strings.Join(hosts, " "))
	b.WriteString("    tls {\n")
	b.WriteString("        protocols tls1.3 tls1.3\n")
	b.WriteString("        issuer acme {\n")
	b.WriteString("            dns cloudflare {env.CF_API_TOKEN}\n")
	if acmeOverrideDomain != "" {
		fmt.Fprintf(&b, "            dns_challenge_override_domain %s\n", caddyQuote(acmeOverrideDomain))
	}
	b.WriteString("            resolvers 1.1.1.1\n")
	b.WriteString("        }\n")
	b.WriteString("        issuer acme\n")
	b.WriteString("    }\n\n")
	b.WriteString("    encode zstd gzip\n\n")
	for index, route := range cfg.Ingress {
		if route.isCatchAll() || !route.BypassAnubis {
			continue
		}
		fmt.Fprintf(&b, "    @bypass%d {\n", index)
		if route.Hostname != "" {
			fmt.Fprintf(&b, "        host %s\n", route.Hostname)
		}
		fmt.Fprintf(&b, "        path_regexp bypass%d %s\n", index, caddyQuote(route.Path))
		if len(route.Methods) > 0 {
			fmt.Fprintf(&b, "        method %s\n", strings.Join(route.Methods, " "))
		}
		b.WriteString("    }\n")
	}
	for index, route := range cfg.Ingress {
		if route.isCatchAll() || route.BypassAnubis || route.RateLimit == nil {
			continue
		}
		renderEdgeRateLimitMatcher(&b, index, route)
	}
	for index, route := range cfg.Ingress {
		if route.isCatchAll() || !route.BypassAnubis {
			continue
		}
		fmt.Fprintf(&b, "    # @bypass%d intentionally bypasses Anubis and edge Coraza; route rate limits still apply.\n", index)
		fmt.Fprintf(&b, "    handle @bypass%d {\n", index)
		b.WriteString("        route {\n")
		b.WriteString("            request_header X-Original-URI {http.request.uri}\n")
		if route.Rewrite != "" {
			fmt.Fprintf(&b, "            rewrite * %s\n", caddyQuote(route.Rewrite))
		}
		if route.RateLimit != nil {
			renderRateLimit(&b, "            ", *route.RateLimit)
		}
		renderEdgeProxyRoute(&b, "            ", route)
		b.WriteString("        }\n")
		b.WriteString("    }\n")
	}
	b.WriteString("    route {\n")
	renderWAF(&b, "        ")
	for index, route := range cfg.Ingress {
		if route.isCatchAll() || route.BypassAnubis || route.RateLimit == nil {
			continue
		}
		fmt.Fprintf(&b, "        # @rate_limit%d applies after Coraza and before Anubis.\n", index)
		fmt.Fprintf(&b, "        handle @rate_limit%d {\n", index)
		b.WriteString("            route {\n")
		renderRateLimit(&b, "                ", *route.RateLimit)
		renderEdgeProxy(&b, "                ", ServiceList{"127.0.0.1:8923"})
		b.WriteString("            }\n")
		b.WriteString("        }\n")
	}
	b.WriteString("        handle {\n")
	renderEdgeProxy(&b, "            ", ServiceList{"127.0.0.1:8923"})
	b.WriteString("        }\n")
	b.WriteString("    }\n")
	renderErrorHandler(&b, "    ")
	b.WriteString("}\n")
	return b.String()
}

func renderHTTPCatchAll(b *strings.Builder, hosts []string) {
	b.WriteString("http://:80 {\n")
	if len(hosts) > 0 {
		fmt.Fprintf(b, "    @known_host host %s\n", strings.Join(hosts, " "))
	}
	b.WriteString("    route {\n")
	if len(hosts) > 0 {
		b.WriteString("        redir @known_host https://{host}{uri} 308\n")
	}
	b.WriteString("        respond 444 {\n")
	b.WriteString("            close\n")
	b.WriteString("        }\n")
	b.WriteString("    }\n")
	b.WriteString("}\n\n")
}

func renderErrorHandler(b *strings.Builder, indent string) {
	body := `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>!!! An unexpected error {err.status_code} occurred !!!</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      body {
        margin: 40px;
        font-family: sans-serif;
        color: #222;
      }

      h1 {
        font-family: monospace;
        font-size: 1.6rem;
        margin-bottom: 0.5em;
      }

      p {
        font-family: monospace;
        font-size: 1.1rem;
        line-height: 1.5;
      }
    </style>
  </head>
  <body>
    <main>
      <h1>Error {err.status_code}</h1>
      <p>{err.message}</p>
      <p>at {err.trace}<br />status: {err.status_code} {err.status_text}<br />id: {err.id}</p>
    </main>
  </body>
</html>`
	fmt.Fprintf(b, "%shandle_errors {\n", indent)
	fmt.Fprintf(b, "%s    header Content-Type \"text/html; charset=utf-8\"\n", indent)
	fmt.Fprintf(b, "%s    header Cache-Control \"no-store\"\n", indent)
	fmt.Fprintf(b, "%s    respond <<GATEWAY_ERROR_HTML\n", indent)
	for _, line := range strings.Split(body, "\n") {
		fmt.Fprintf(b, "%s    %s\n", indent, line)
	}
	fmt.Fprintf(b, "%s    GATEWAY_ERROR_HTML\n", indent)
	fmt.Fprintf(b, "%s}\n", indent)
}

func renderRateLimit(b *strings.Builder, indent string, limit RateLimit) {
	key := limit.Key
	if key == "" {
		key = "{remote_host}"
	}
	fmt.Fprintf(b, "%srate_limit {\n", indent)
	fmt.Fprintf(b, "%s    zone %s {\n", indent, limit.Name)
	if len(limit.Methods) > 0 {
		fmt.Fprintf(b, "%s        match {\n", indent)
		fmt.Fprintf(b, "%s            method %s\n", indent, strings.Join(limit.Methods, " "))
		fmt.Fprintf(b, "%s        }\n", indent)
	}
	fmt.Fprintf(b, "%s        key %s\n", indent, key)
	fmt.Fprintf(b, "%s        window %s\n", indent, limit.Window)
	fmt.Fprintf(b, "%s        events %d\n", indent, limit.Events)
	if limit.IPv4Prefix != 0 {
		fmt.Fprintf(b, "%s        ipv4_prefix %d\n", indent, limit.IPv4Prefix)
	}
	if limit.IPv6Prefix != 0 {
		fmt.Fprintf(b, "%s        ipv6_prefix %d\n", indent, limit.IPv6Prefix)
	}
	fmt.Fprintf(b, "%s    }\n", indent)
	fmt.Fprintf(b, "%s}\n", indent)
}

func renderEdgeProxy(b *strings.Builder, indent string, services ServiceList) {
	renderReverseProxy(b, indent, services, "", nil, true, false, false, "")
}

func renderEdgeRateLimitMatcher(b *strings.Builder, index int, route Route) {
	fmt.Fprintf(b, "    @rate_limit%d {\n", index)
	if route.Hostname != "" {
		fmt.Fprintf(b, "        host %s\n", route.Hostname)
	}
	if route.Path != "" {
		fmt.Fprintf(b, "        path_regexp rate_limit%d %s\n", index, caddyQuote(route.Path))
	}
	if len(route.Methods) > 0 {
		fmt.Fprintf(b, "        method %s\n", strings.Join(route.Methods, " "))
	}
	b.WriteString("    }\n")
}

func renderEdgeProxyRoute(b *strings.Builder, indent string, route Route) {
	var health *normalizedHealth
	if route.Health != nil {
		normalized := route.health()
		health = &normalized
	}
	renderReverseProxy(b, indent, route.Service, route.LoadBalance, health, true, false, true, "")
}

func renderReverseProxy(b *strings.Builder, indent string, services ServiceList, loadBalance string, health *normalizedHealth, edgeHeaders bool, streamCloseDelay bool, preserveOriginalURI bool, cacheResponseMatcher string) {
	fmt.Fprintf(b, "%sreverse_proxy", indent)
	for _, service := range services {
		fmt.Fprintf(b, " %s", service)
	}
	b.WriteString(" {\n")
	if edgeHeaders {
		fmt.Fprintf(b, "%s    header_up X-Forwarded-For {http.request.remote.host}\n", indent)
		fmt.Fprintf(b, "%s    header_up X-Real-IP {http.request.remote.host}\n", indent)
		fmt.Fprintf(b, "%s    header_up X-Client-IP {http.request.remote.host}\n", indent)
		fmt.Fprintf(b, "%s    header_up X-Forwarded-Proto {http.request.scheme}\n", indent)
		fmt.Fprintf(b, "%s    header_up X-Forwarded-Host {http.request.host}\n", indent)
		fmt.Fprintf(b, "%s    header_up X-Forwarded-Port {http.request.port}\n", indent)
		fmt.Fprintf(b, "%s    header_up X-Forwarded-Uri {http.request.uri}\n", indent)
		fmt.Fprintf(b, "%s    header_up X-Forwarded-Method {http.request.method}\n", indent)
		if preserveOriginalURI {
			fmt.Fprintf(b, "%s    header_up X-Original-URI {http.request.header.X-Original-URI}\n", indent)
		} else {
			fmt.Fprintf(b, "%s    header_up X-Original-URI {http.request.uri}\n", indent)
		}
		fmt.Fprintf(b, "%s    header_up X-Http-Version {http.request.proto}\n", indent)
	}
	if len(services) > 1 && loadBalance != "" {
		fmt.Fprintf(b, "%s    lb_policy %s\n", indent, loadBalance)
	}
	if health != nil && health.Active {
		fmt.Fprintf(b, "%s    health_uri %s\n", indent, health.URI)
		fmt.Fprintf(b, "%s    health_interval %s\n", indent, health.Interval)
		fmt.Fprintf(b, "%s    health_timeout %s\n", indent, health.Timeout)
		fmt.Fprintf(b, "%s    lb_try_duration %s\n", indent, health.TryDuration)
	}
	if streamCloseDelay {
		fmt.Fprintf(b, "%s    stream_close_delay 5m\n", indent)
	}
	if cacheResponseMatcher != "" {
		fmt.Fprintf(b, "%s    @%s {\n", indent, cacheResponseMatcher)
		fmt.Fprintf(b, "%s        header Set-Cookie *\n", indent)
		fmt.Fprintf(b, "%s    }\n", indent)
		fmt.Fprintf(b, "%s    handle_response @%s {\n", indent, cacheResponseMatcher)
		fmt.Fprintf(b, "%s        header >Cache-Control \"no-store\"\n", indent)
		fmt.Fprintf(b, "%s        header >Souin-Cache-Control \"no-store\"\n", indent)
		fmt.Fprintf(b, "%s        header >Surrogate-Control \"no-store\"\n", indent)
		fmt.Fprintf(b, "%s        header >CDN-Cache-Control \"no-store\"\n", indent)
		fmt.Fprintf(b, "%s        copy_response\n", indent)
		fmt.Fprintf(b, "%s    }\n", indent)
	}
	fmt.Fprintf(b, "%s}\n", indent)
}

func renderOrigin(cfg Config) string {
	var b strings.Builder
	for index, route := range cfg.Ingress {
		if route.isCatchAll() || route.BypassAnubis {
			continue
		}
		renderMatcher(&b, index, route)
		if route.isProxyRoute() && route.cacheEnabled() {
			renderCacheMatcher(&b, index)
		}
		b.WriteString("\n")
	}

	for index, route := range cfg.Ingress {
		if route.isCatchAll() || route.BypassAnubis {
			continue
		}
		fmt.Fprintf(&b, "handle @route%d {\n", index)
		if route.Redirect != "" {
			fmt.Fprintf(&b, "    redir %s 302\n", caddyQuote(route.Redirect))
		} else if route.MetaRedirect != "" {
			renderMetaRedirect(&b, "    ", route.MetaRedirect)
		} else {
			b.WriteString("    route {\n")
			if route.cacheEnabled() {
				cache := route.cachePolicy()
				fmt.Fprintf(&b, "        cache @cacheable%d {\n", index)
				fmt.Fprintf(&b, "            ttl %s\n", cache.TTL)
				fmt.Fprintf(&b, "            stale %s\n", cache.Stale)
				b.WriteString("            mode strict\n")
				fmt.Fprintf(&b, "            default_cache_control %s\n", caddyQuote(cache.DefaultCacheControl))
				fmt.Fprintf(&b, "            max_cacheable_body_bytes %d\n", cache.MaxCacheableBodyBytes)
				b.WriteString("            key {\n")
				b.WriteString("                hide\n")
				b.WriteString("            }\n")
				b.WriteString("            otter {\n")
				b.WriteString("                configuration {\n")
				b.WriteString("                    size 50000\n")
				b.WriteString("                }\n")
				b.WriteString("            }\n")
				b.WriteString("        }\n")
			}
			if route.Rewrite != "" {
				fmt.Fprintf(&b, "        rewrite * %s\n", caddyQuote(route.Rewrite))
			}
			renderProxy(&b, "        ", route, index)
			b.WriteString("    }\n")
		}
		b.WriteString("}\n\n")
	}

	renderErrorHandler(&b, "")

	b.WriteString("respond 444 {\n")
	b.WriteString("    close\n")
	b.WriteString("}\n")
	return b.String()
}

func (r Route) isProxyRoute() bool {
	return r.Redirect == "" && r.MetaRedirect == ""
}

func renderMetaRedirect(b *strings.Builder, indent string, target string) {
	body := fmt.Sprintf(
		"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0;url=%s\"><title>Continue</title></head><body><a href=\"%s\">Continue</a></body></html>",
		html.EscapeString(target),
		html.EscapeString(target),
	)
	b.WriteString(indent + "header {\n")
	b.WriteString(indent + "    Content-Type \"text/html; charset=utf-8\"\n")
	b.WriteString(indent + "    Cache-Control \"no-store\"\n")
	b.WriteString(indent + "}\n")
	fmt.Fprintf(b, "%srespond %s 200\n", indent, caddyQuote(body))
}

func renderMatcher(b *strings.Builder, index int, route Route) {
	fmt.Fprintf(b, "@route%d {\n", index)
	if route.Hostname != "" {
		fmt.Fprintf(b, "    host %s\n", route.Hostname)
	}
	if route.Path != "" {
		fmt.Fprintf(b, "    path_regexp route%d %s\n", index, caddyQuote(route.Path))
	}
	if len(route.Methods) > 0 {
		fmt.Fprintf(b, "    method %s\n", strings.Join(route.Methods, " "))
	}
	b.WriteString("}\n")
}

func renderCacheMatcher(b *strings.Builder, index int) {
	fmt.Fprintf(b, "@cacheable%d {\n", index)
	b.WriteString("    method GET HEAD\n")
	b.WriteString("    not header Cookie *\n")
	b.WriteString("    not header Authorization *\n")
	b.WriteString("    not header Cache-Control *no-cache*\n")
	b.WriteString("    not header Cache-Control *no-store*\n")
	b.WriteString("    not header Pragma *no-cache*\n")
	b.WriteString("    not header Connection *Upgrade*\n")
	b.WriteString("    not header Upgrade *\n")
	b.WriteString("    not header Upgrade websocket\n")
	b.WriteString("    not path /api /api/* /login* /logout* /admin* /healthz /healthz/*\n")
	b.WriteString("}\n")
}

func renderWAF(b *strings.Builder, indent string) {
	fmt.Fprintf(b, "%scoraza_waf {\n", indent)
	fmt.Fprintf(b, "%s    load_owasp_crs\n\n", indent)
	fmt.Fprintf(b, "%s    directives `\n", indent)
	fmt.Fprintf(b, "%s        Include @coraza.conf-recommended\n", indent)
	fmt.Fprintf(b, "%s        Include @crs-setup.conf.example\n", indent)
	fmt.Fprintf(b, "%s        Include /usr/share/gateway/config/caddy/waf/overrides.conf\n", indent)
	fmt.Fprintf(b, "%s        Include @owasp_crs/*.conf\n", indent)
	fmt.Fprintf(b, "%s        SecRuleEngine On\n", indent)
	fmt.Fprintf(b, "%s        SecResponseBodyAccess Off\n", indent)
	fmt.Fprintf(b, "%s    `\n", indent)
	fmt.Fprintf(b, "%s}\n", indent)
}

func renderProxy(b *strings.Builder, indent string, route Route, index int) {
	health := route.health()
	matcher := ""
	if route.cacheEnabled() {
		matcher = fmt.Sprintf("cache_response_%d", index)
	}
	renderReverseProxy(b, indent, route.Service, route.LoadBalance, &health, false, true, false, matcher)
}

func caddyQuote(value string) string {
	return strconv.Quote(value)
}

func hasUnsafeText(value string) bool {
	return strings.ContainsAny(value, "\r\n`\"")
}

func writeAtomically(path string, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".routes-*.tmp")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0644); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.WriteString(content); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, path)
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "route-renderer: %s\n", err)
	os.Exit(1)
}
