# Building the binary of the App
FROM golang:1.19 AS build

WORKDIR /go/src/tasky
# We'll copy the tasky directory contents during the build command
COPY tasky/ .
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /go/src/tasky/tasky


FROM alpine:3.17.0 as release

WORKDIR /app
COPY --from=build  /go/src/tasky/tasky .
COPY --from=build  /go/src/tasky/assets ./assets
RUN mkdir -p /app/public
COPY wizexercise.txt /app/public/

# Install mongosh
# Add legacy MongoDB repositories and install mongo shell
RUN echo 'http://dl-cdn.alpinelinux.org/alpine/v3.9/main' >> /etc/apk/repositories && \
    echo 'http://dl-cdn.alpinelinux.org/alpine/v3.9/community' >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache mongodb mongodb-tools

EXPOSE 8080
ENTRYPOINT ["/app/tasky"]