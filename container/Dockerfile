# One small program on Alpine. Its one dependency (golang.org/x/text, for
# Unicode file names) is vendored, so the build downloads only the base images.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
COPY vendor ./vendor
COPY *.go ./
RUN CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags="-s -w" -o /lrc-nas-publisher .

FROM alpine:3.24
RUN apk add --no-cache tzdata
COPY --from=build /lrc-nas-publisher /usr/local/bin/lrc-nas-publisher
EXPOSE 8765
HEALTHCHECK --interval=1m --timeout=5s --start-period=20s CMD wget -qO /dev/null http://127.0.0.1:8765/healthz || exit 1
# Go handles docker stop (SIGTERM) itself: it lets the upload in progress finish.
ENTRYPOINT ["lrc-nas-publisher"]
CMD ["serve"]
