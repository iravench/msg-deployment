CURRENT_DIR=$(shell pwd)
REGISTRY_ADDR=$(shell docker-machine ip infra):5000

MYSQL_CONTAINER_NAME=msg-storage-mysql
MYSQL_DATABASE=bex-msg
MYSQL_USER=pink
MYSQL_PASSWORD=5678
MYSQL_INIT=$(shell cat $(CURRENT_DIR)/../msg-storage/init.sql)

RABBIT_CONTAINER_NAME=msg-storage-rabbit

REDIS_CONTAINER_NAME=msg-storage-redis

FM_1_ADDR=$(shell docker-machine ip swarm-1)
FM_2_ADDR=$(shell docker-machine ip swarm-2)

all:
	@echo "Available targets:"
	@echo "  * up           - start msg app on local swarm cluster"
	@echo "  * down         - stop & remove msg app from local swarm cluster"
	@echo "  * mysql_cli    - start mysql command line interface, can be used after msg app is up"
overlay:
	docker network create --driver overlay msg-overlay
mysql:
	docker run -d -e constraint:storage==1 --name $(MYSQL_CONTAINER_NAME) -p 3306:3306 --net msg-overlay \
	  -e MYSQL_ROOT_PASSWORD=pink5678 \
	  -e MYSQL_DATABASE=$(MYSQL_DATABASE) \
	  -e MYSQL_USER=$(MYSQL_USER) \
	  -e MYSQL_PASSWORD=$(MYSQL_PASSWORD) \
	  $(REGISTRY_ADDR)/mysql
mysql_cli:
	docker run -it --net msg-overlay --rm $(REGISTRY_ADDR)/mysql sh -c \
	  'exec mysql \
	  -h"$(MYSQL_CONTAINER_NAME)" \
	  -P"3306" \
	  -D"$(MYSQL_DATABASE)" \
	  -u"$(MYSQL_USER)" \
	  -p"$(MYSQL_PASSWORD)"'
mysql_init:
	docker run -it --net msg-overlay --rm $(REGISTRY_ADDR)/mysql sh -c \
	  'exec mysql \
	  -h"$(MYSQL_CONTAINER_NAME)" \
	  -P"3306" \
	  -D"$(MYSQL_DATABASE)" \
	  -u"$(MYSQL_USER)" \
	  -p"$(MYSQL_PASSWORD)" \
	  -e"$(MYSQL_INIT)"'
rabbit:
	docker run -d -e constraint:storage==1 -p 15672:15672 -p 5672:5672 --net msg-overlay \
	  --name $(RABBIT_CONTAINER_NAME) \
	  --hostname $(RABBIT_CONTAINER_NAME) \
	  -e RABBITMQ_ERLANG_COOKIE='pink5678' \
	  -e RABBITMQ_DEFAULT_USER=guest \
	  -e RABBITMQ_DEFAULT_PASS=guest \
	  rabbitmq:3-management
redis:
	docker run -d -e constraint:storage==1 -p 6379:6379 --net msg-overlay \
	  --name $(REDIS_CONTAINER_NAME) \
	  --hostname $(REDIS_CONTAINER_NAME) \
	  redis:alpine
up: down overlay mysql rabbit redis
	until $(MAKE) mysql_init; do sleep 1s; done # retry until mysql container is up and properly initialized
	docker run -d -e constraint:broker==1 --name msg-session-broker -p 80:8080 --net msg-overlay \
	  -e MYSQL_IP=$(MYSQL_CONTAINER_NAME) \
	  -e REDIS_IP=$(REDIS_CONTAINER_NAME) \
	  $(REGISTRY_ADDR)/msg-session-broker
	docker run -d -e constraint:manager==1 --name msg-session-manager-1 -p 80:9090 --net msg-overlay \
	  -e MYSQL_IP=$(MYSQL_CONTAINER_NAME) \
	  -e REDIS_IP=$(REDIS_CONTAINER_NAME) \
	  -e RABBIT_IP=$(RABBIT_CONTAINER_NAME) \
	  -e FM_ID=fm-1 \
	  -e FM_IP=$(FM_1_ADDR) \
	  -e FM_PORT=80 \
	  $(REGISTRY_ADDR)/msg-session-manager
	docker run -d -e constraint:manager==2 --name msg-session-manager-2 -p 80:9090 --net msg-overlay \
	  -e MYSQL_IP=$(MYSQL_CONTAINER_NAME) \
	  -e REDIS_IP=$(REDIS_CONTAINER_NAME) \
	  -e RABBIT_IP=$(RABBIT_CONTAINER_NAME) \
	  -e FM_ID=fm-2 \
	  -e FM_IP=$(FM_2_ADDR) \
	  -e FM_PORT=80 \
	  $(REGISTRY_ADDR)/msg-session-manager
down: FORCE
	docker kill --signal=SIGINT msg-session-broker || true
	docker kill --signal=SIGINT msg-session-manager-1 || true
	docker kill --signal=SIGINT msg-session-manager-2 || true
	docker rm msg-session-broker || true
	docker rm msg-session-manager-1 || true
	docker rm msg-session-manager-2 || true
	docker rm -f $(MYSQL_CONTAINER_NAME) || true
	docker rm -f $(RABBIT_CONTAINER_NAME) || true
	docker rm -f $(REDIS_CONTAINER_NAME) || true
	docker network rm msg-overlay || true
FORCE:
