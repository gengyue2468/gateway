package main

import (
	"errors"
	"flag"
	"fmt"
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
)

type Config struct {
	Version int     `yaml:"version"`
	Ingress []Route `yaml:"ingress"`
}

type Route struct {
	Hostname    string        `yaml:"hostname,omitempty"`
	Path        string        `yaml:"path,omitempty"`
	Service     ServiceList   `yaml:"service"`
	Cache       *bool         `yaml:"cache,omitempty"`
	LoadBalance string        `yaml:"load_balance,omitempty"`
	Health      *HealthConfig `yaml:"health,omitempty"`
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
	URI         string `yaml:"uri,omitempty"`
	Interval    string `yaml:"interval,omitempty"`
	Timeout     string `yaml:"timeout,omitempty"`
	TryDuration string `yaml:"try_duration,omitempty"`
}

type normalizedHealth struct {
	URI         string
	Interval    string
	Timeout     string
	TryDuration string
}

var hostnamePattern = regexp.MustCompile(`^(\*\.)?[A-Za-z0-9][A-Za-z0-9._:-]*$`)

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

	if *checkOnly {
		return
	}

	if err := writeAtomically(*edgeOutput, renderEdge(cfg)); err != nil {
		fatal(fmt.Errorf("write edge config: %w", err))
	}
	if err := writeAtomically(*originOutput, renderOrigin(cfg)); err != nil {
		fatal(fmt.Errorf("write origin config: %w", err))
	}
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
	if route.Hostname == "" && route.Path == "" && !route.isCatchAll() {
		return fmt.Errorf("%s must declare hostname or path", prefix)
	}
	if len(route.Service) == 0 {
		return fmt.Errorf("%s service must not be empty", prefix)
	}
	if route.isCatchAll() {
		if !isLast {
			return fmt.Errorf("%s catch-all must be the final rule", prefix)
		}
		if route.Cache != nil || route.LoadBalance != "" || route.Health != nil {
			return fmt.Errorf("%s catch-all cannot have route options", prefix)
		}
		return nil
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

var validLoadBalancers = map[string]bool{
	"random":         true,
	"first":          true,
	"round_robin":    true,
	"least_conn":     true,
	"ip_hash":        true,
	"client_ip_hash": true,
	"uri_hash":       true,
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

func (r Route) isCatchAll() bool {
	return r.Hostname == "" && r.Path == "" && len(r.Service) == 1 && r.Service[0] == "http_status:444"
}

func (r Route) cacheEnabled() bool {
	return r.Cache == nil || *r.Cache
}

func (r Route) health() normalizedHealth {
	result := normalizedHealth{
		URI:         "/healthz",
		Interval:    "30s",
		Timeout:     "5s",
		TryDuration: "5s",
	}
	if r.Health == nil {
		return result
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

func renderEdge(cfg Config) string {
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
	b.WriteString("    email {$ACME_EMAIL}\n\n")
	b.WriteString("    servers :443 {\n")
	b.WriteString("        protocols h1 h2 h3\n")
	b.WriteString("    }\n")
	b.WriteString("}\n\n")
	if len(hosts) == 0 {
		return b.String()
	}
	fmt.Fprintf(&b, "%s {\n", strings.Join(hosts, " "))
	b.WriteString("    tls {\n")
	b.WriteString("        protocols tls1.3 tls1.3\n")
	b.WriteString("        dns cloudflare {env.CF_API_TOKEN}\n")
	b.WriteString("        resolvers 1.1.1.1\n")
	b.WriteString("    }\n\n")
	b.WriteString("    reverse_proxy 127.0.0.1:8923 {\n")
	b.WriteString("        header_up X-Forwarded-For {remote_host}\n")
	b.WriteString("        header_up X-Real-IP {remote_host}\n")
	b.WriteString("        header_up X-Http-Version {http.request.proto}\n")
	b.WriteString("    }\n")
	b.WriteString("}\n")
	return b.String()
}

func renderOrigin(cfg Config) string {
	var b strings.Builder
	for index, route := range cfg.Ingress {
		if route.isCatchAll() {
			continue
		}
		renderMatcher(&b, index, route)
		if route.cacheEnabled() {
			renderCacheMatcher(&b, index)
		}
		b.WriteString("\n")
	}

	for index, route := range cfg.Ingress {
		if route.isCatchAll() {
			continue
		}
		fmt.Fprintf(&b, "handle @route%d {\n", index)
		b.WriteString("    route {\n")
		renderWAF(&b, "        ")
		if route.cacheEnabled() {
			fmt.Fprintf(&b, "        handle @cacheable%d {\n", index)
			b.WriteString("            cache {\n")
			b.WriteString("                ttl 10m\n")
			b.WriteString("                default_cache_control no-store\n")
			b.WriteString("                otter {\n")
			b.WriteString("                    configuration {\n")
			b.WriteString("                        size 50000\n")
			b.WriteString("                    }\n")
			b.WriteString("                }\n")
			b.WriteString("            }\n")
			renderProxy(&b, "            ", route)
			b.WriteString("        }\n")
		}
		renderProxy(&b, "        ", route)
		b.WriteString("    }\n")
		b.WriteString("}\n\n")
	}

	b.WriteString("respond 444 {\n")
	b.WriteString("    close\n")
	b.WriteString("}\n")
	return b.String()
}

func renderMatcher(b *strings.Builder, index int, route Route) {
	fmt.Fprintf(b, "@route%d {\n", index)
	if route.Hostname != "" {
		fmt.Fprintf(b, "    host %s\n", route.Hostname)
	}
	if route.Path != "" {
		fmt.Fprintf(b, "    path_regexp route%d %s\n", index, caddyQuote(route.Path))
	}
	b.WriteString("}\n")
}

func renderCacheMatcher(b *strings.Builder, index int) {
	fmt.Fprintf(b, "@cacheable%d {\n", index)
	b.WriteString("    method GET HEAD\n")
	b.WriteString("    not header Cookie *\n")
	b.WriteString("    not header Authorization *\n")
	b.WriteString("    not header Connection *Upgrade*\n")
	b.WriteString("    not header Upgrade websocket\n")
	b.WriteString("    not path /api/* /login* /logout* /admin* /healthz\n")
	b.WriteString("}\n")
}

func renderWAF(b *strings.Builder, indent string) {
	fmt.Fprintf(b, "%scoraza_waf {\n", indent)
	fmt.Fprintf(b, "%s    load_owasp_crs\n\n", indent)
	fmt.Fprintf(b, "%s    directives `\n", indent)
	fmt.Fprintf(b, "%s        Include @coraza.conf-recommended\n", indent)
	fmt.Fprintf(b, "%s        Include @crs-setup.conf.example\n", indent)
	fmt.Fprintf(b, "%s        Include @owasp_crs/*.conf\n", indent)
	fmt.Fprintf(b, "%s        Include /usr/share/gateway/config/caddy/waf/overrides.conf\n", indent)
	fmt.Fprintf(b, "%s        SecRuleEngine On\n", indent)
	fmt.Fprintf(b, "%s    `\n", indent)
	fmt.Fprintf(b, "%s}\n", indent)
}

func renderProxy(b *strings.Builder, indent string, route Route) {
	fmt.Fprintf(b, "%sreverse_proxy", indent)
	for _, service := range route.Service {
		fmt.Fprintf(b, " %s", service)
	}
	b.WriteString(" {\n")
	if len(route.Service) > 1 && route.LoadBalance != "" {
		fmt.Fprintf(b, "%slb_policy %s\n", indent+"    ", route.LoadBalance)
	}
	health := route.health()
	fmt.Fprintf(b, "%shealth_uri %s\n", indent+"    ", health.URI)
	fmt.Fprintf(b, "%shealth_interval %s\n", indent+"    ", health.Interval)
	fmt.Fprintf(b, "%shealth_timeout %s\n", indent+"    ", health.Timeout)
	fmt.Fprintf(b, "%slb_try_duration %s\n", indent+"    ", health.TryDuration)
	fmt.Fprintf(b, "%sstream_close_delay 5m\n", indent+"    ")
	fmt.Fprintf(b, "%s}\n", indent)
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
