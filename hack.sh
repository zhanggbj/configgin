#!/bin/bash

# This will rebuild configgin for the image
set -o errexit -o nounset

REPO="${REPO:-scf}"

IMAGE="$( cd "../${REPO}" && source .envrc && echo "$FISSILE_STEMCELL" )"

name="${IMAGE%%:*}"
tag="${IMAGE##*:}"

unset container
unset KUBECONFIG

cleanup() {
    if test -n "${container:-}" ; then
        docker rm -f "${container}"
    fi
    if test -n "${KUBECONFIG:-}" ; then
        rm -f  "${KUBECONFIG}"
    fi
}
trap cleanup EXIT

# Force use the vagrant kubectl context
export KUBECONFIG="$(mktemp)"
kubectl config set-cluster vagrant --server=http://cf-dev.io:8080
kubectl config set-context vagrant --cluster=vagrant --user=""
kubectl config use-context vagrant

vagrant_ready=""
if test -z "${NO_RUN:-}" ; then
    if ( cd "$(dirname "$0")/../${REPO}" && (vagrant status 2>/dev/null | grep --quiet running) ) ; then
        vagrant_ready="true"
        helm list --short | xargs --no-run-if-empty helm delete --purge
        kubectl delete ns cf ||:
        kubectl delete ns uaa ||:
    fi
fi

if test -z "$(docker images --quiet "${name}:${tag}-orig" 2>/dev/null)" ; then
    docker pull "${IMAGE}"
    container=$(docker run --detach "${IMAGE}" /bin/bash -c "sleep 1d")
    docker exec -t "${container}" zypper install -y git
    docker commit "${container}" "${name}:${tag}-orig"
fi

container=$(docker run \
    --volume "${PWD}:/src" \
    --detach \
    "${name}:${tag}-orig" \
    /bin/bash -c "sleep 1d")
docker exec -t "${container}" /bin/bash -c "source /usr/local/rvm/scripts/rvm && make -C /src all"
docker exec -t "${container}" /bin/bash -c "source /usr/local/rvm/scripts/rvm && gem install /src/configgin-*.gem"
docker commit "${container}" "${IMAGE}"

test -z "${NO_RUN:-}" || exit

docker_user=$(docker system info | awk -F: '{ if ($1 == "Username") { print  $2} }' | tr -d '[:space:]' ||:)
if test -n "${docker_user}" ; then
    docker tag "${IMAGE}" "${docker_user}/${name##*/}:${tag}"
    docker push "${docker_user}/${name##*/}:${tag}"
fi

test -n "${vagrant_ready}" || exit

cd "$(dirname "$0")/../${REPO}"
if ! (vagrant status 2>/dev/null | grep --quiet running) ; then
    exit 0
fi

vagrant ssh -- -tt <<EOF
    set -o errexit -o nounset
    docker pull ${docker_user}/${name##*/}:${tag}
    docker tag ${docker_user}/${name##*/}:${tag} ${IMAGE}
    cd scf
    source .envrc
    while kubectl get namespace cf >/dev/null 2>/dev/null ; do
        sleep 1
    done
    while kubectl get namespace uaa >/dev/null 2>/dev/null ; do
        sleep 1
    done
    docker images --format={{.Repository}}:{{.Tag}} | \
        grep -E '/scf-|role-packages' | \
        xargs --no-run-if-empty docker rmi -f
    docker images | \
        awk '/<none>/ { print \$3 }' | \
        xargs --no-run-if-empty docker rmi -f || \
        :
    make compile images helm kube run </dev/null
    exit 0
EOF
