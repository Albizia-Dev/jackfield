FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -o /jackfield-server ./cmd/server

FROM alpine:3.22
RUN adduser -D -H jackfield
USER jackfield
COPY --from=builder /jackfield-server /jackfield-server
EXPOSE 8080
ENTRYPOINT ["/jackfield-server"]
