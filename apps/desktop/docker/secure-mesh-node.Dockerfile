FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG APT_LISTS_ROOT_NAME=var
ARG INSTALL_ROOT_NAME=opt

ENV CLIENT_ROOT="/${INSTALL_ROOT_NAME}/lico/client"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      libdbus-1-3 \
      libgcc-s1 \
      libsecret-1-0 \
      libstdc++6 \
    && rm -rf "/${APT_LISTS_ROOT_NAME}/lib/apt/lists"/*

COPY client ${CLIENT_ROOT}

WORKDIR ${CLIENT_ROOT}

RUN test -x ./licoup \
    && test -f ./package-metadata/licoup/packaging-modules.json

USER 65534:65534

CMD ["sleep", "infinity"]
