# Build stage: Compile the binary using an official Go image (Alpine-based)
FROM golang:1.24-alpine AS builder

# Set the working directory inside the container
WORKDIR /app

# Copy go.mod and go.sum first to leverage Docker layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy the rest of the source code (ensure this Dockerfile lives in the same directory as main.go)
COPY . .

# Build the binary with CGO disabled for a fully static build
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bondi-server main.go

# Final stage: Use the scratch image for a minimal runtime
FROM scratch

# Copy the compiled binary from the builder stage into the scratch image
COPY --from=builder /app/bondi-server /bondi-server

# Expose the port on which the server listens (3030)
EXPOSE 3030

# Set the entrypoint to run the server
ENTRYPOINT ["/bondi-server"]
