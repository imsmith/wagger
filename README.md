# Wagger

Your application has a finite set of valid endpoints. Your WAF should know about them. Wagger bridges the gap: define your routes once, generate WAF configs for whatever platform you're deploying to.

Eight generators ship today -- AWS WAF, Cloudflare, Azure Front Door, GCP Cloud Armor, Nginx, Caddy, Coraza/ModSecurity, and an OWASP ZAP test plan generator that verifies your deployed config is actually blocking what it should.

Import routes from OpenAPI specs, bulk text, or access logs. Share API definitions through the public Hub. Get notified when your routes drift from the last generated config.

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
