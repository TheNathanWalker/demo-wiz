# Building the binary of the App
# Many golang vulnerabilities are fixed in the latest version of golang
# FROM golang:1.19 AS build
FROM golang:1.24.2 AS build

WORKDIR /go/src/tasky
COPY tasky/ .
# fix the golang.org/x/crypto vulnerability. I hope!
RUN go mod tidy
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /go/src/tasky/tasky


#FROM alpine:3.17.0 as release
# Updated to latest stable
FROM alpine:3.21.3 AS release 

WORKDIR /app
COPY --from=build  /go/src/tasky/tasky .
COPY --from=build  /go/src/tasky/assets ./assets
# Redundant line to copy wizexercise.txt
COPY --from=build  /go/src/tasky/assets/wizexercise.txt ./assets/wizexercise.txt
RUN mkdir -p /app/public

# Install mongosh
# Add legacy MongoDB repositories and install mongo shell
RUN echo 'http://dl-cdn.alpinelinux.org/alpine/v3.9/main' >> /etc/apk/repositories && \
    echo 'http://dl-cdn.alpinelinux.org/alpine/v3.9/community' >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache mongodb mongodb-tools

# Fix CVE-2024-5535 by upgrading to OpenSSL 3.3.3
RUN apk update && \
    apk upgrade openssl && \
    apk add --no-cache openssl

EXPOSE 8080
ENTRYPOINT ["/app/tasky"]