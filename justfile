# https://cheatography.com/linux-china/cheat-sheets/justfile/

IMAGE_NAME := "mlopez1506/bondi-server"

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
