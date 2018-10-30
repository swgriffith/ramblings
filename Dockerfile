FROM alpine:3.8
LABEL maintainer="steve.griffith@microsoft.com"
RUN apk update && apk add bash hugo git openssh && rm -rf /var/cache/apk/*
RUN mkdir /work
WORKDIR /work
RUN git clone https://github.com/swgriffith/ramblings.git

EXPOSE 1313
ENTRYPOINT [ "/bin/bash" ]