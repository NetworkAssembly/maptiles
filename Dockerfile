FROM debian:bookworm-slim AS tilemaker-compile

RUN apt update && DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    git curl unzip cmake ca-certificates \
    build-essential libboost-dev libboost-filesystem-dev libboost-iostreams-dev libboost-program-options-dev libboost-system-dev liblua5.1-0-dev libshp-dev libsqlite3-dev rapidjson-dev zlib1g-dev
RUN update-ca-certificates
RUN git clone https://github.com/systemed/tilemaker.git /tilemaker

WORKDIR /tilemaker/build
RUN cmake -DCMAKE_BUILD_TYPE=Release ..
RUN cmake --build . --parallel $(nproc)

WORKDIR /tilemaker/coastline
RUN curl -O https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip
RUN unzip -oj water-polygons-split-4326.zip

FROM debian:bookworm-slim AS tilemaker-generate

RUN apt update && DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    curl ca-certificates jq moreutils \
    liblua5.1-0 shapelib libsqlite3-0 libboost-filesystem-dev libboost-program-options-dev libboost-iostreams-dev
RUN update-ca-certificates

WORKDIR /tilemaker

COPY --from=tilemaker-compile /tilemaker/build/tilemaker .
COPY --from=tilemaker-compile /tilemaker/resources ./resources
COPY --from=tilemaker-compile /tilemaker/coastline ./coastline

RUN jq ".settings.include_ids=true" resources/config-openmaptiles.json | sponge resources/config-openmaptiles.json

RUN curl -O https://download.geofabrik.de/europe/turkey-latest.osm.pbf
RUN ./tilemaker --fast --input=turkey-latest.osm.pbf --output=turkey.mbtiles --config=resources/config-openmaptiles.json --process=resources/process-openmaptiles.lua

FROM golang:alpine AS tileserver-build

RUN apk update && apk add git build-base
RUN git clone https://github.com/consbio/mbtileserver.git /tileserver

WORKDIR /tileserver
RUN GOOS=linux go build -o tileserver

FROM alpine AS tileserver-runtime

WORKDIR /tileserver

COPY --from=tileserver-build /tileserver/tileserver .
COPY --from=tilemaker-generate /tilemaker/turkey.mbtiles ./tilesets/turkey.mbtiles

ENTRYPOINT [ "/tileserver/tileserver", "--dir=/tileserver/tilesets", "--disable-preview", "--disable-tilejson" ]
