FROM debian:bookworm-slim AS tilemaker-compile

RUN apt update && DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    git curl unzip cmake ca-certificates \
    build-essential libboost-dev libboost-filesystem-dev libboost-iostreams-dev libboost-program-options-dev libboost-system-dev liblua5.1-0-dev libshp-dev libsqlite3-dev rapidjson-dev zlib1g-dev
RUN update-ca-certificates
RUN git clone https://github.com/systemed/tilemaker.git --single-branch --depth 1 /tilemaker

WORKDIR /tilemaker/build
RUN cmake -DCMAKE_BUILD_TYPE=Release ..
RUN cmake --build . --parallel $(nproc)

WORKDIR /tilemaker/coastline
RUN curl -O https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip
RUN unzip -oj water-polygons-split-4326.zip

WORKDIR /tilemaker/landcover
RUN curl -O https://naciscdn.org/naturalearth/10m/physical/ne_10m_antarctic_ice_shelves_polys.zip
RUN curl -O https://naciscdn.org/naturalearth/10m/physical/ne_10m_glaciated_areas.zip
RUN curl -O https://naciscdn.org/naturalearth/10m/cultural/ne_10m_urban_areas.zip
RUN unzip -o ne_10m_antarctic_ice_shelves_polys.zip -d ne_10m_antarctic_ice_shelves_polys
RUN unzip -o ne_10m_glaciated_areas.zip -d ne_10m_glaciated_areas
RUN unzip -o ne_10m_urban_areas.zip -d ne_10m_urban_areas

FROM debian:bookworm-slim AS tilemaker-generate

RUN apt update && DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    curl ca-certificates jq moreutils \
    liblua5.1-0 shapelib libsqlite3-0 libboost-filesystem-dev libboost-program-options-dev libboost-iostreams-dev
RUN update-ca-certificates

WORKDIR /tilemaker

COPY --from=tilemaker-compile /tilemaker/build/tilemaker .
COPY --from=tilemaker-compile /tilemaker/resources ./resources
COPY --from=tilemaker-compile /tilemaker/coastline ./coastline
COPY --from=tilemaker-compile /tilemaker/landcover ./landcover

RUN jq '.settings.include_ids=true | .settings.maxzoom = 16 | .settings.basezoom = 16 | .settings.combine_below = 16 | .layers.building.minzoom = 12 | (.layers[] | .maxzoom) |= if . == 14 then 16 else . end' resources/config-openmaptiles.json | sponge resources/config-openmaptiles.json

RUN curl -O https://download.geofabrik.de/europe/turkey-latest.osm.pbf
RUN ./tilemaker --fast --no-compress-nodes --no-compress-ways --materialize-geometries --input=turkey-latest.osm.pbf --output=turkey.mbtiles --config=resources/config-openmaptiles.json --process=resources/process-openmaptiles.lua

FROM golang:alpine AS tileserver-build

RUN apk update && apk add git build-base
RUN git clone https://github.com/consbio/mbtileserver.git --single-branch --depth 1 /tileserver

WORKDIR /tileserver
RUN GOOS=linux go build -o tileserver

FROM alpine AS tileserver-runtime

WORKDIR /tileserver

COPY --from=tileserver-build /tileserver/tileserver .
COPY --from=tilemaker-generate /tilemaker/turkey.mbtiles ./tilesets/turkey.mbtiles

ENTRYPOINT [ "/tileserver/tileserver", "--dir=/tileserver/tilesets" ]
