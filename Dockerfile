# Build stage
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.1
ARG ALPINE_VERSION=3.21.3

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION} AS build

RUN apk add --no-cache build-base git

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config/config.exs config/runtime.exs config/
COPY lib lib
COPY priv priv
COPY yang yang
COPY assets assets

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

EXPOSE 4000

CMD ["bin/wagger", "start"]
