# https://cheatography.com/linux-china/cheat-sheets/justfile/

IMAGE_NAME := "mlopez1506/bondi-server"

docker-all TAG: build-server (tag-server TAG) (push-server TAG) (update-bondi-version TAG) run-setup run-deploy

build-server:
	docker build -t {{IMAGE_NAME}} ./server

tag-server TAG:
	docker tag {{IMAGE_NAME}}:latest {{IMAGE_NAME}}:{{TAG}}

push-server TAG:
	docker push {{IMAGE_NAME}}:{{TAG}}

server-docker:
	docker run --name bondi -p 3030:3030 -v /var/run/docker.sock:/var/run/docker.sock --rm {{IMAGE_NAME}}

server:
	go run server/main.go

lint:
	golangci-lint run cli/... server/...

build:
	go build -v ./cli/... ./server/...

test:
    go test -v -coverpkg=./cli/...,./server/... -coverprofile=profile.cov ./cli/... ./server/...
    # go tool cover -func profile.cov | tee /dev/stderr | awk 'END{if($3+0 < 15.0) {exit 1}}'

update-bondi-version TAG:
    sed -i "s/version: .*/version: {{TAG}}/g" cli/bondi.yaml

run-setup:
    cd cli && env $(cat .env | xargs) go run ./main.go setup

run-deploy VERSION='0.0.6':
    cd cli && env $(cat .env | xargs) go run ./main.go deploy {{VERSION}}
