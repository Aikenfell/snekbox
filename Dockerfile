# syntax=docker/dockerfile:1
FROM buildpack-deps:buster as builder-nsjail

WORKDIR /nsjail

RUN apt-get -y update \
    && apt-get install -y --no-install-recommends \
        bison\
        flex \
        libprotobuf-dev\
        libnl-route-3-dev \
        protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

RUN git clone -b master --single-branch https://github.com/google/nsjail.git . \
    && git checkout dccf911fd2659e7b08ce9507c25b2b38ec2c5800
RUN make

# ------------------------------------------------------------------------------
FROM buildpack-deps:buster as builder-py-base

ENV PYENV_ROOT=/pyenv \
    PYTHON_CONFIGURE_OPTS='--disable-test-modules --enable-optimizations \
        --with-lto --with-system-expat --without-ensurepip'

RUN apt-get -y update \
    && apt-get install -y --no-install-recommends \
        libxmlsec1-dev \
        tk-dev \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/build_python.sh /

# ------------------------------------------------------------------------------
FROM builder-py-base as builder-py-3_11
RUN git clone -b v2.3.24 --depth 1 https://github.com/pyenv/pyenv.git $PYENV_ROOT \
    && /build_python.sh 3.11.4

# ------------------------------------------------------------------------------
FROM builder-py-base as builder-py-3_12
RUN git clone -b v2.3.24 --depth 1 https://github.com/pyenv/pyenv.git $PYENV_ROOT \
    && /build_python.sh 3.12.0rc1

# ------------------------------------------------------------------------------
FROM python:3.11-slim-buster as base

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=false

RUN apt-get -y update \
    && apt-get install -y --no-install-recommends \
        gcc \
        git \
        libnl-route-3-200 \
        libprotobuf17 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder-nsjail /nsjail/nsjail /usr/sbin/
COPY --from=builder-py-3_11 /lang/ /lang/
COPY --from=builder-py-3_12 /lang/ /lang/

RUN chmod +x /usr/sbin/nsjail \
    && ln -s /lang/python/3.11/ /lang/python/default

# ------------------------------------------------------------------------------
FROM base as venv

COPY requirements/ /snekbox/requirements/
WORKDIR /snekbox

RUN pip install -U -r requirements/requirements.pip

# This must come after the first pip command! From the docs:
# All RUN instructions following an ARG instruction use the ARG variable
# implicitly (as an environment variable), thus can cause a cache miss.
ARG DEV

# Install numpy when in dev mode; one of the unit tests needs it.
RUN if [ -n "${DEV}" ]; \
    then \
        pip install -U -r requirements/coverage.pip \
        && PYTHONUSERBASE=/snekbox/user_base \
        && /lang/python/default/bin/python -m pip install --user numpy~=1.19; \
    fi

# At the end to avoid re-installing dependencies when only a config changes.
COPY config/ /snekbox/config/

ENTRYPOINT ["gunicorn"]
CMD ["-c", "config/gunicorn.conf.py"]

# ------------------------------------------------------------------------------
FROM venv

# Use a separate directory to avoid importing the source over the installed pkg.
# The venv already installed dependencies, so nothing besides snekbox itself
# will be installed. Note requirements.pip cannot be used as a constraint file
# because it contains extras, which pip disallows.
RUN --mount=source=.,target=/snekbox_src,rw \
    pip install /snekbox_src[gunicorn,sentry]
