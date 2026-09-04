FROM dart:stable AS build

WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart pub get --offline

RUN dart compile exe bin/server.dart -o bin/server

# Use the same dart:stable image as our final runtime image too.
# It already contains the full Dart runtime AND a complete Debian
# system (with apt-get), so we do NOT need to manually copy Dart's
# /runtime/ folder (that trick is only needed for a totally empty
# "FROM scratch" image). This avoids the "/lib" conflict we hit
# when trying to combine /runtime/ with debian:bookworm-slim.
FROM dart:stable

WORKDIR /app

# Install trusted certificates so both our server and the Deno JS
# solver below can make secure (https) requests to YouTube.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

# Copy just the Deno binary (a small JavaScript runtime) — YouTube now
# requires solving a small JS "challenge" for some requests, and this
# is what lets our server do that automatically.
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

# Copy only our compiled server executable from the build stage.
COPY --from=build /app/bin/server /app/bin/server

EXPOSE 8080
CMD ["/app/bin/server"]