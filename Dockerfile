FROM dart:stable AS build

WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart pub get --offline

RUN dart compile exe bin/server.dart -o bin/server

FROM debian:bookworm-slim

# Install a trusted-certificates package, so both our server and the
# Deno JS solver below can make secure (https) requests to YouTube.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

# Copy just the Deno binary (a small JavaScript runtime) — YouTube now
# requires solving a small JS "challenge" for some requests, and this
# is what lets our server do that automatically.
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

COPY --from=build /runtime/ /
COPY --from=build /app/bin/server /app/bin/

EXPOSE 8080
CMD ["/app/bin/server"]