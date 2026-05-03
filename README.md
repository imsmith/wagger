# Wagger

Your application has a finite set of valid endpoints. Your WAF should know about them. Wagger bridges the gap: define your routes once, generate WAF configs for whatever platform you're deploying to.

Eight generators ship today -- AWS WAF, Cloudflare, Azure Front Door, GCP Cloud Armor, Nginx, Caddy, Coraza/ModSecurity, and an OWASP ZAP test plan generator that verifies your deployed config is actually blocking what it should.

Import routes from OpenAPI specs, bulk text, or access logs. Share API definitions through the public Hub. Get notified when your routes drift from the last generated config.

## GCP

Wagger emits two artifacts for GCP: `gcp-armor.json` (Cloud Armor security policy — rate limiting, IP/geo posture, defense-in-depth) and `gcp-urlmap.json` (URL Map fragment — the default-deny gate for `(method, path)` allowlisting via `pathTemplateMatch` + `:method` headerMatches).

Deployment sketch: URL Map attaches to the Global External HTTPS Load Balancer; Cloud Armor attaches to the known-traffic `backendServices` referenced by the URL Map's matched routeRules. The deployer provides a deny backend (a small Cloud Run service or serverless NEG returning 403) referenced by the URL Map's `defaultService` and `pathMatchers[].defaultService` and the URL Map's final default-deny route-rule's `service`. Wagger emits placeholders `__KNOWN_TRAFFIC_BACKEND__` and `__DENY_BACKEND__` (overridable via config) which the deployer substitutes for real `projects/PROJECT_ID/.../backendServices/...` refs.

Targets Global External Application Load Balancer and other modern ALB variants where `pathTemplateMatch` is supported. Classic ALB is unsupported by `Wagger.Generator.GcpUrlMap` because `pathTemplateMatch` is unavailable there; users on Classic ALB can use `Wagger.Generator.Gcp` (Cloud Armor) alone, but with much tighter scaling limits on the path allowlist.

For the full story -- why the architecture looks the way it does, how the generators work under the hood, and what the YANG validation layer is about -- read the [literate program](docs/waf-rule-generator-literate.md).

## Running it

With Elixir installed:

```sh
git clone https://github.com/imsmith/wagger.git
cd wagger
mix setup
mix phx.server
```

Without Elixir:

```sh
docker build -t wagger .
docker run -p 4000:4000 \
  -e SECRET_KEY_BASE=$(openssl rand -base64 48) \
  -e PHX_HOST=localhost \
  -v wagger_data:/data \
  wagger
```

Either way, open [localhost:4000](http://localhost:4000).

## Dependencies

Wagger pulls two libraries that are also ours:

- [comn](https://github.com/imsmith/comn) -- shared infrastructure (structured errors, request contexts, event bus, encryption at rest)
- [ex_yang](https://github.com/imsmith/ex_yang) -- YANG model parser used to validate generator output before serialization

Both resolve automatically via `mix deps.get`.

## License

AGPL-3.0
