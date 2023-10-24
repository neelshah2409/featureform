# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

##############################################  HELP  ##################################################################

define HELP_BODY
To run unit tests, run:
	make test

usage: make [target] [options]
TARGETS
help
	Description:
		Prints this help message

init
	Requirements:
		- Python 3.7-3.10
		- Golang 1.18

	Description:
		Installs grpc-tools with pip and builds the proto files for the serving and metadata connections for the
		Python client and Golang libraries. It then builds and installs the Python SDK and CLI.


test
	Requirements:
		- Python 3.7-3.10
		- Golang 1.18
	Description:
		Runs 'init' then runs the Python and Golang Unit tests

test_offline
	Requirements:
		- Golang 1.18

	Description:
		Runs offline store integration tests. Requires credentials if not using the memory provider

	Options:
		- provider (memory | postgres | snowflake | redshift | bigquery | spark )
			Description:
				Runs specified provider. If left blank or not included, runs all providers
			Usage:
				make test_offline provider=memory

test_online
	Requirements:
		- Golang 1.18

	Description:
		Runs online store integration tests. Requires credentials if not using the memory or redis_mock provider

	Options:
		- provider (memory | redis_mock | redis_insecure | redis_secure | cassandra | firestore | dynamo )
			Description:
				Runs specified provider. If left blank or not included, runs all providers
			Usage:
				make test_online provider=memory


test_go_unit
	Requirements:
		- Golang 1.18

	Description:
		Runs golang unit tests

test_metadata
	Requirements:
		- Golang 1.18
		- ETCD installed and added to path (https://etcd.io/docs/v3.4/install/)

	Description:
		Runs metadata tests

	Flags:
		- ETCD_UNSUPPORTED_ARCH
			Description:
				This flag must be set to run on M1/M2 Macs
			Usage:
				make test_metadata flags=ETCD_UNSUPPORTED_ARCH=arm64


test_helpers
	Requirements:
		- Golang 1.18

	Description:
		Runs helper tests

test_serving
	Requirements:
		- Golang 1.18

	Description:
		Runs serving tests

test_runner
	Requirements:
		- Golang 1.18
		- ETCD installed and added to path (https://etcd.io/docs/v3.4/install/)

	Description:
		Runs coordinator runner tests

	Flags:
		- ETCD_UNSUPPORTED_ARCH
			Description:
				This flag must be set to run on M1/M2 Macs
			Usage:
				make test_metadata flags=ETCD_UNSUPPORTED_ARCH=arm64

test_api
	Requirements:
		- Golang 1.18
		- Python3.6-3.10

	Description:
		Starts an API Server instance and checks that the serving and metadata clients can connect

test_typesense
	Requirements:
		- Golang 1.18
		- Docker

	Description:
		Starts a typesense instance and tests the typesense package

test_coordinator
	Requirements:
		- Golang 1.18
		- ETCD installed and added to path (https://etcd.io/docs/v3.4/install/)
		- Docker

	Description:
		Starts ETCD, Postgres, and Redis to test the coordinator

	Flags:
		- ETCD_UNSUPPORTED_ARCH
			Description:
				This flag must be set to run on M1/M2 Macs
			Usage:
				make test_metadata flags=ETCD_UNSUPPORTED_ARCH=arm64

test_filestore
	Requirements:
		- Golang 1.18

	Description:
		Runs golang unit tests

endef
export HELP_BODY

help:
	@echo "$$HELP_BODY"  |  less

##############################################  UNIT TESTS #############################################################

init: update_python

test: init pytest test_go_unit

##############################################  SETUP ##################################################################

gen_grpc:						## Generates GRPC Dependencies
	python3 -m pip install grpcio-tools

	-mkdir client/src/featureform/proto/
	cp metadata/proto/metadata.proto client/src/featureform/proto/metadata.proto
	cp proto/serving.proto client/src/featureform/proto/serving.proto

	protoc --go_out=. --go_opt=paths=source_relative     --go-grpc_out=. --go-grpc_opt=paths=source_relative     ./proto/serving.proto
	python3 -m grpc_tools.protoc -I ./client/src --python_out=./client/src --grpc_python_out=./client/src/ ./client/src/featureform/proto/serving.proto

	protoc --go_out=. --go_opt=paths=source_relative     --go-grpc_out=. --go-grpc_opt=paths=source_relative     ./metadata/proto/metadata.proto
	python3 -m grpc_tools.protoc -I ./client/src --python_out=./client/src/ --grpc_python_out=./client/src/ ./client/src/featureform/proto/metadata.proto

update_python: gen_grpc 				## Updates the python package locally
	pip3 install pytest
	pip3 install build
	pip3 uninstall featureform  -y
	-rm -r client/dist/*
	python3 -m build ./client/
	pip3 install client/dist/*.whl
	pip3 install -r provider/scripts/spark/requirements.txt

etcdctl: 						## Installs ETCDCTL. Required for reset_e2e
	-git clone -b v3.4.16 https://github.com/etcd-io/etcd.git
	cd etcd && ./build
	export PATH=$PATH:"`pwd`/etcd/bin"
	etcdctl version

credentials:
	-mkdir ~/credentials
	aws secretsmanager get-secret-value --secret-id bigquery.json --region us-east-1 |   jq -r '.SecretString' > ~/credentials/bigquery.json
	aws secretsmanager get-secret-value --secret-id firebase.json --region us-east-1 |   jq -r '.SecretString' > ~/credentials/firebase.json
	aws secretsmanager get-secret-value --secret-id .env --region us-east-1 |   jq -r '.SecretString' |   jq -r "to_entries|map(\"\(.key)=\\\"\(.value|tostring)\\\"\")|.[]" > .env

start_postgres:
	-docker kill postgres
	-docker rm postgres
	docker run -d -p 5432:5432 --name postgres -e POSTGRES_PASSWORD=password postgres

stop_postgres:
	docker kill postgres
	docker rm postgres

##############################################  PYTHON TESTS ###########################################################
pytest:
	-rm -r .featureform
	curl -C - https://featureform-demo-files.s3.amazonaws.com/transactions_short.csv -o transactions.csv
	python -m pytest client/tests/local_dash_test.py
	python -m pytest client/tests/status_test.py
	python -m pytest client/tests/test_cli.py
	python -m pytest client/tests/resources_test.py
	python -m pytest client/tests/register_test.py
	python -m pytest client/tests/provider_config_test.py
	python -m pytest client/tests/serving_test.py
	python -m pytest client/tests/redefined_test.py
#	python -m pytest client/tests/local_test.py
	python -m pytest client/tests/localmode_quickstart_test.py
	python -m pytest client/tests/register_test.py
	python -m pytest client/tests/test_spark_provider.py
	python -m pytest client/tests/test_localmode_include_label_ts.py
	python -m pytest client/tests/test_localmode_lag_features.py
	python -m pytest client/tests/test_localmode_caching.py
	python -m pytest client/tests/test_metadata_repository.py
	python -m pytest client/tests/test_parse.py
	python -m pytest client/tests/test_autogenerated_variants.py
	python -m pytest -m 'local' client/tests/test_serving_model.py
	python -m pytest -m 'local' client/tests/test_getting_model.py
	python -m pytest -m 'local' client/tests/test_search.py
	python -m pytest -m 'local' client/tests/test_tags_and_properties.py
	python -m pytest -m 'local' client/tests/test_class_api.py
	python -m pytest -m 'local' client/tests/test_ondemand_features.py
	python -m pytest -m 'local' client/tests/test_resource_registration.py
	python -m pytest -m 'local' client/tests/test_source_dataframe.py
	python -m pytest -m 'local' client/tests/test_training_set_dataframe.py
	python -m pytest -m 'local' client/tests/get_provider_test.py
	-rm -r .featureform
	-rm -f transactions.csv

pytest_coverage:
	-rm -r .featureform
	curl -C - https://featureform-demo-files.s3.amazonaws.com/transactions_short.csv -o transactions.csv
	python -m pytest -v -s -m 'local' --cov=client/src/featureform client/tests/ --cov-report=xml
	-rm -r .featureform
	-rm -f transactions.csv

jupyter: update_python
	pip3 install jupyter nbconvert matplotlib pandas scikit-learn requests
	jupyter nbconvert --to notebook --execute notebooks/Fraud_Detection_Example.ipynb

test_pyspark:
	@echo "Requires Java to be installed"
	pytest -v -s --cov=offline_store_spark_runner provider/scripts/spark/tests/ --cov-report term-missing

test_pandas:
	pytest -v -s --cov=offline_store_pandas_runner provider/scripts/k8s/tests/ --cov-report term-missing


##############################################  GO TESTS ###############################################################
test_offline: gen_grpc 					## Run offline tests. Run with `make test_offline provider=(memory | postgres | snowflake | redshift | spark )`
	@echo "These tests require a .env file. Please Check .env-template for possible variables"
	-mkdir coverage
	go test -v -parallel 1000 -timeout 60m -coverpkg=./... -coverprofile coverage/cover.out.tmp ./provider --tags=offline,filepath --provider=$(provider)

test_offline_spark: gen_grpc 					## Run spark tests.
	@echo "These tests require a .env file. Please Check .env-template for possible variables"
	-mkdir coverage
	go test -v -parallel 1000 -timeout 60m -coverpkg=./... -coverprofile coverage/cover.out.tmp ./provider --tags=spark

test_offline_k8s:  					## Run k8s tests.
	@echo "These tests require a .env file. Please Check .env-template for possible variables"
	-mkdir coverage
	go test -v -parallel 1000 -timeout 60m -coverpkg=./... -coverprofile coverage/cover.out.tmp ./provider/... --tags=k8s

test_filestore:
	@echo "These tests require a .env file. Please Check .env-template for possible variables"
	-mkdir coverage
	go test -v -timeout 60m -coverpkg=./... -coverprofile coverage/cover.out.tmp ./provider/... --tags=filestore


test_online: gen_grpc 					## Run offline tests. Run with `make test_online provider=(memory | redis_mock | redis_insecure | redis_secure | cassandra | firestore | dynamo )`
	@echo "These tests require a .env file. Please Check .env-template for possible variables"
	-mkdir coverage
	go test -v -coverpkg=./... -coverprofile coverage/cover.out.tmp ./provider --tags=online,provider --provider=$(provider)

test_go_unit:
	-mkdir coverage
	go test ./... -tags=*,offline,provider --short   -coverprofile coverage/cover.out.tmp

test_metadata:							## Requires ETCD to be installed and added to path
	-mkdir coverage
	$(flags) etcd &
	while ! echo exit | nc localhost 2379; do sleep 1; done
	go test -coverpkg=./... -coverprofile coverage/cover.out.tmp ./metadata/

test_helpers:
	-mkdir coverage
	go test -v -coverpkg=./... -coverprofile coverage/cover.out.tmp ./helpers/...

test_serving:
	-mkdir coverage
	go test -v -coverpkg=./... -coverprofile coverage/cover.out.tmp ./serving/...

test_runner:							## Requires ETCD to be installed and added to path
	-mkdir coverage
	$(flags) etcd &
	while ! echo exit | nc localhost 2379; do sleep 1; done
	go test -v -coverpkg=./... -coverprofile coverage/cover.out.tmp ./runner/...

test_api: update_python
	pip3 install -U pip
	pip3 install python-dotenv pytest
	go run api/main.go & echo $$! > server.PID;
	while ! echo exit | nc localhost 7878; do sleep 1; done
	pytest client/tests/connection_test.py
	kill -9 `cat server.PID`

test_typesense:
	-docker kill typesense
	-docker rm typesense
	-mkdir coverage
	-mkdir /tmp/typesense-data
	docker run -d --name typesense -p 8108:8108 -v/tmp/typesense-data:/data typesense/typesense:0.23.1 --data-dir /data --api-key=xyz --enable-cors
	go test -v -coverpkg=./... -coverprofile ./coverage/cover.out.tmp ./metadata/search/...
	docker kill typesense
	docker rm typesense

test_coordinator: cleanup_coordinator
	-mkdir coverage
	docker run -d --name postgres -p 5432:5432 -e POSTGRES_PASSWORD=password postgres
	docker run -d --name redis -p 6379:6379 redis
	$(flags) etcd &
	while ! echo exit | nc localhost 2379; do sleep 1; done
	while ! echo exit | nc localhost 5432; do sleep 1; done
	while ! echo exit | nc localhost 6379; do sleep 1; done
	go test -v -coverpkg=./... -coverprofile coverage/cover.out.tmp ./coordinator/...
	$(MAKE) cleanup_coordinator

cleanup_coordinator:
	-docker kill postgres
	-docker rm postgres
	-docker kill redis
	-docker rm redis

test_healthchecks: ## Run health check tests. Run with `make test_healthchecks provider=(redis | postgres | snowflake | dynamo | spark )`
	@echo "These tests require a .env file. Please Check .env-template for possible variables"
	-mkdir coverage
	go test -v -coverpkg=./... -coverprofile coverage/cover.out.tmp ./health --tags=health --provider=$(provider)


##############################################  MINIKUBE ###############################################################

containers: gen_grpc						## Build Docker containers for Minikube
	minikube image build --v=3 -f ./api/Dockerfile . -t local/api-server:stable & \
	minikube image build --v=3 -f ./dashboard/Dockerfile . -t local/dashboard:stable & \
	minikube image build --v=3 -f ./coordinator/Dockerfile.old --build-opt=build-arg=TESTING=True . -t local/coordinator:stable & \
	minikube image build --v=3 -f ./metadata/Dockerfile . -t local/metadata:stable & \
	minikube image build --v=3 -f ./metadata/dashboard/Dockerfile . -t local/metadata-dashboard:stable & \
	minikube image build --v=3 -f ./serving/Dockerfile . -t local/serving:stable & \
	minikube image build --v=3 -f ./runner/Dockerfile --build-opt=build-arg=TESTING=True . -t local/worker:stable & \
	minikube image build --v=3 -f ./provider/scripts/k8s/Dockerfile . -t local/k8s_runner:stable & \
	minikube image build --v=3 -f ./provider/scripts/k8s/Dockerfile.scikit . -t local/k8s_runner:stable-scikit & \
	wait; \
	echo "Build Complete"

start_minikube:	##Starts Minikube
	minikube start --kubernetes-version=v1.23.12

reset_minikube:	##Resets Minikube
	minikube delete
	minikube start --kubernetes-version=v1.23.12

install_featureform: start_minikube containers		## Configures Featureform on Minikube
	helm repo add jetstack https://charts.jetstack.io
	helm repo update
	helm install certmgr jetstack/cert-manager \
        --set installCRDs=true \
        --version v1.8.0 \
        --namespace cert-manager \
        --create-namespace
	helm install featureform ./charts/featureform --set global.repo=local --set global.pullPolicy=Never --set global.version=stable
	kubectl get secret featureform-ca-secret -o=custom-columns=':.data.tls\.crt'| base64 -d > tls.crt
	export FEATUREFORM_HOST=localhost:443
    export FEATUREFORM_CERT=tls.crt

test_e2e: update_python					## Runs End-to-End tests on minikube
	pip3 install requests
	-helm install quickstart ./charts/quickstart
	kubectl wait --for=condition=complete job/featureform-quickstart-loader --timeout=720s
	kubectl wait --for=condition=READY=true pod -l app.kubernetes.io/name=ingress-nginx --timeout=720s
	kubectl wait --for=condition=READY=true pod -l app.kubernetes.io/name=etcd --timeout=720s
	kubectl wait --for=condition=READY=true pod -l chart=featureform --timeout=720s

	-kubectl port-forward svc/featureform-ingress-nginx-controller 8000:443 7000:80 &
	-kubectl port-forward svc/featureform-etcd 2379:2379 &

	while ! echo exit | nc localhost 7000; do sleep 10; done
	while ! echo exit | nc localhost 2379; do sleep 10; done

	featureform apply --no-wait client/examples/quickstart.py --host localhost:8000 --cert tls.crt
	pytest client/tests/e2e.py
	pytest -m 'hosted' client/tests/test_serving_model.py
	pytest -m 'hosted' client/tests/test_getting_model.py
	pytest -m 'hosted' client/tests/test_updating_provider.py
	pytest -m 'hosted' client/tests/test_class_api.py
	pytest -m 'hosted' client/tests/test_source_dataframe.py
	pytest -m 'hosted' client/tests/test_training_set_dataframe.py
#	pytest -m 'hosted' client/tests/test_search.py

	 echo "Starting end to end tests"
	 ./tests/end_to_end/end_to_end_tests.sh localhost:8000 ./tls.crt

reset_e2e:  			 			## Resets Cluster. Requires install_etcd
	-kubectl port-forward svc/featureform-etcd 2379:2379 &
	while ! echo exit | nc localhost 2379; do sleep 10; done
	etcdctl --user=root:secretpassword del "" --prefix
	-helm uninstall quickstart
