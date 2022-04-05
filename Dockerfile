# syntax = docker/dockerfile:1.2

# create an image that has everything we need to build
# we can build only this image and work interactively
FROM ubuntu:20.04 AS builddep_light
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    python3 \
    python3-numpy \
    python3-distutils \
    python3-dev \
    python3-pyaudio \
    python-dev \
    libasound2 \
#The following 2 lines are to address CVE. Might not be needed when we change base image
    libexpat1 \
    libexpat1-dev \
    libsndfile1 \
    libglib2.0-0 \
    zlib1g \
    libbz2-1.0 \
    liblzma5 \
    libboost-system-dev \
    libboost-thread-dev \
    libboost-program-options-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -O https://bootstrap.pypa.io/get-pip.py && \
    python3 get-pip.py && \
    rm get-pip.py

RUN pip3 install --upgrade requests grpcio-tools notebook librosa editdistance "ipython>=7.31.1"
RUN pip3 uninstall -y click

# Dependencies for building
FROM builddep_light AS builddep
ARG BAZEL_VERSION=3.7.2

RUN apt-get update && apt-get install -y \
    pkg-config \
    unzip \
    zip \
    wget \
    flac \
    libflac++-dev \
    parallel \
    alsa-base \
    libasound2-dev \
    linux-libc-dev \
    alsa-utils \
    bc \
    build-essential \
    cmake \
    libboost-test-dev \
    zlib1g-dev \
    libbz2-dev \
    liblzma-dev \
    git \
    vim \
    sox \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --upgrade sklearn transformers

RUN wget https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/bazel-${BAZEL_VERSION}-installer-linux-x86_64.sh && \
    chmod +x bazel-${BAZEL_VERSION}-installer-linux-x86_64.sh && \
    ./bazel-${BAZEL_VERSION}-installer-linux-x86_64.sh --user && \
    echo "PATH=/root/bin:$PATH\n" >> /root/.bashrc && \
    echo "source /root/.bazel/bin/bazel-complete.bash" >> /root/.bashrc && \
    rm ./bazel-${BAZEL_VERSION}-installer-linux-x86_64.sh
ENV PATH="/root/bin:${PATH}"

#Install NGC client.
RUN wget https://ngc.nvidia.com/downloads/ngccli_bat_linux.zip && unzip ngccli_bat_linux.zip && chmod u+x ngc && \
    echo "PATH=/:$PATH\n" >> /root/.bashrc
RUN md5sum -c ngc.md5
ENV PATH="/:${PATH}"


# copy the source and run build
FROM builddep as builder

WORKDIR /work
COPY .bazelrc WORKSPACE ./
COPY ./riva/proto /work/riva/proto
COPY ./riva/utils /work/riva/utils
COPY ./riva/clients /work/riva/clients
COPY third_party /work/third_party
ARG BAZEL_CACHE_ARG=""
RUN --mount=type=cache,sharing=locked,target=/root/.cache/bazel bazel build $BAZEL_CACHE_ARG \
        //riva/clients/asr:riva_asr_client \
        //riva/clients/asr:riva_streaming_asr_client \
        //riva/clients/tts:riva_tts_client \
        //riva/clients/tts:riva_tts_perf_client \
        //riva/clients/nlp:riva_nlp_classify_tokens \
        //riva/clients/nlp:riva_nlp_qa \
        //riva/clients/nlp:riva_nlp_punct \
        //riva/clients/asr/... && \
    bazel test $BAZEL_CACHE_ARG //riva/clients/... --test_summary=detailed --test_output=all && \
    cp -R /work/bazel-bin/riva /opt

COPY python /work/python
RUN python3 python/clients/setup.py bdist_wheel

# create lightweight client image
FROM builddep_light AS riva-api-client

ENV PYTHONPATH="${PYTHONPATH}:/work/"

WORKDIR /work
COPY --from=builder /opt/riva/clients/asr/riva_asr_client /usr/local/bin/
COPY --from=builder /opt/riva/clients/asr/riva_streaming_asr_client /usr/local/bin/
COPY --from=builder /opt/riva/clients/tts/riva_tts_client /usr/local/bin
COPY --from=builder /opt/riva/clients/tts/riva_tts_perf_client /usr/local/bin
COPY --from=builder /opt/riva/clients/nlp/riva_nlp_classify_tokens /usr/local/bin/
COPY --from=builder /opt/riva/clients/nlp/riva_nlp_qa /usr/local/bin/
COPY --from=builder /opt/riva/clients/nlp/riva_nlp_punct /usr/local/bin/
COPY --from=builder /work/riva/proto/ /work/riva/proto/
COPY --from=builder /work/dist /work
RUN pip install *.whl
RUN python3 -m pip uninstall -y pip
COPY ./scripts/calc_wer.py utils/calc_wer.py
COPY ./python/clients/asr/*.py ./examples/
COPY ./python/clients/nlp/riva_nlp/test_qa.py ./examples/
COPY ./python/clients/tts/talk_stream.py ./examples/
COPY ./python/clients/tts/talk.py ./examples/

# create client image for CI and devel
FROM builddep AS riva-api-client-dev

ENV PYTHONPATH="${PYTHONPATH}:/work/"

WORKDIR /work
COPY --from=builder /work/dist /work
RUN pip install *.whl
#Uninstall pip to address CVE-2018-20225
RUN python3 -m pip uninstall -y pip
COPY --from=builder /opt/riva/clients/asr/riva_asr_client /usr/local/bin/
COPY --from=builder /opt/riva/clients/asr/riva_streaming_asr_client /usr/local/bin/
COPY --from=builder /opt/riva/clients/tts/riva_tts_client /usr/local/bin/
COPY --from=builder /opt/riva/clients/tts/riva_tts_perf_client /usr/local/bin
COPY --from=builder /opt/riva/clients/nlp/riva_nlp_classify_tokens /usr/local/bin/
COPY --from=builder /opt/riva/clients/nlp/riva_nlp_qa /usr/local/bin/
COPY --from=builder /opt/riva/clients/nlp/riva_nlp_punct /usr/local/bin/
COPY --from=builder /work/riva/proto/ /work/riva/proto/

COPY ./scripts/ scripts
COPY ./python/clients/nlp/riva_nlp/test_qa.py ./examples/
COPY ./python/clients/asr/*.py ./examples/
COPY ./python/clients/tts/*.py ./examples/
COPY ./python/clients/nlp/*.py ./examples/
