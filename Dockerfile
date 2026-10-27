ARG IMAGE=docker.iscinternal.com/docker-intersystems/intersystems/iris-community:2026.3.0AI.154.0
FROM $IMAGE

WORKDIR /home/irisowner/dev

ARG NAMESPACE="IRISAPP"

ENV IRISUSERNAME "_SYSTEM"
ENV IRISPASSWORD "SYS"
ENV IRISNAMESPACE $NAMESPACE
ENV PATH "/usr/irissys/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/irisowner/bin"

COPY merge.cpf /home/irisowner/dev/merge.cpf
COPY iris.script /home/irisowner/dev/iris.script

RUN --mount=type=bind,src=.,dst=. \
    iris start IRIS && \
    sleep 5 && \
    iris merge IRIS /home/irisowner/dev/merge.cpf && \
    sleep 5 && \
    iris session IRIS < iris.script && \
    iris stop IRIS quietly
