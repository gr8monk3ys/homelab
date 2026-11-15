#!/usr/bin/env bash
# Restore an app's PVC from its VolSync restic backup in B2.
#
#   ./hack/restore.sh <namespace> <app>              # overwrite PVC <app> in place
#   ./hack/restore.sh <namespace> <app> --previous 2 # the third-newest snapshot
#   ./hack/restore.sh <namespace> <app> --test       # restore into a scratch PVC,
#                                                    # list it, delete it (app untouched)
#
# In place: suspends the app's Flux Kustomization (named <app>), scales
# Deployment <app> to 0, restores, then resumes Flux, which scales it back. Run --test monthly: a backup never restored is not a backup.
set -euo pipefail

ns=${1:?usage: restore.sh <namespace> <app> [--previous N] [--test]}
app=${2:?usage: restore.sh <namespace> <app> [--previous N] [--test]}
shift 2
previous=0
test=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --previous) previous=${2:?}; shift 2 ;;
    --test) test=true; shift ;;
    *) echo "unknown argument $1" >&2; exit 1 ;;
  esac
done

trigger="restore-$(date +%s)"
target=$app
if $test; then
  target=$app-restore-test
  kubectl -n "$ns" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $target
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi
EOF
else
  read -rp "Overwrite PVC $ns/$app with snapshot -$previous from B2? [y/N] " ok
  [[ $ok == y ]] || exit 1
  flux suspend kustomization "$app"
  trap 'flux resume kustomization "$app"' EXIT
  # Convention: Deployment <app> is the one writer of PVC <app>.
  kubectl -n "$ns" scale deployment "$app" --replicas=0
  kubectl -n "$ns" wait --for=delete pod -l "app.kubernetes.io/name=$app" --timeout=5m || true
fi

kubectl -n "$ns" apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: $app-restore
spec:
  trigger:
    manual: $trigger
  restic:
    repository: $app-volsync
    destinationPVC: $target
    copyMethod: Direct
    previous: $previous
    moverSecurityContext:
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
EOF
echo "restoring $ns/$target (watch: kubectl -n $ns get pods -w)"
kubectl -n "$ns" wait replicationdestination "$app-restore" \
  --for=jsonpath='{.status.lastManualSync}'="$trigger" --timeout=2h
kubectl -n "$ns" get replicationdestination "$app-restore" -o jsonpath='{.status.latestMoverStatus.result}{"\n"}'
kubectl -n "$ns" delete replicationdestination "$app-restore"

if $test; then
  kubectl -n "$ns" run "$app-restore-check" --rm -i --restart=Never --image=busybox:1.37 \
    --overrides='{"spec":{"securityContext":{"runAsUser":1000,"runAsGroup":1000,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"busybox:1.37","command":["sh","-c","du -sh /r; ls -la /r | head -30"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"r","mountPath":"/r"}]}],"volumes":[{"name":"r","persistentVolumeClaim":{"claimName":"'"$target"'"}}]}}'
  kubectl -n "$ns" delete pvc "$target"
fi
