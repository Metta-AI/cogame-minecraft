# Build Docker. ONE image, TWO entrypoints: /bin/minecraft (the game server,
# which also makes every LLM call) and /bin/minecraft-player (the thin seat
# registrar). The policy set is env-switched inside this same image
# (PLAYER_PROMPT vs PLAYER_SCRIPTED), which is what keeps a champion and a
# scripted filler byte-identical apart from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/minecraft
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on --path:src"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/minecraft-nimcache \
  --out:minecraft \
  src/minecraft.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/minecraft-player-nimcache \
  --out:minecraft-player \
  src/minecraft_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/minecraft
COPY --from=build /workspace/minecraft/minecraft /bin/minecraft
COPY --from=build /workspace/minecraft/minecraft-player /bin/minecraft-player
COPY --from=build /workspace/minecraft/*.json ./
COPY --from=build /workspace/minecraft/data ./data

CMD ["/bin/minecraft"]
