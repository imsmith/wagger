# Build stage
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG ALPINE_VERSION=3.24.2

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION} AS build

RUN apk add --no-cache build-base git

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY lib lib
COPY priv priv
COPY yang yang
COPY assets assets
COPY rel rel

RUN mix assets.setup
RUN mix assets.deploy
RUN mix compile
RUN mix release

# Runtime stage
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache libstdc++ libgcc ncurses-libs

WORKDIR /app

ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV DATABASE_PATH=/data/wagger.db

RUN mkdir -p /data

COPY --from=build /app/_build/prod/rel/wagger ./

EXPOSE 8080

CMD ["bin/wagger", "start"]
