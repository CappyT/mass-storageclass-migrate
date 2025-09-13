# mass-storageclass-migrate
Scripts for mass-migration of storageclasses in kubernetes

## Why this?
I'm lazy. But I also often test out new storage types in my cluster or I just re-ingeneer the whole thing.

## What does it do?
These scripts will provide an easy way for you to move ALL data between two storageclasses.
It also *RETAINS* the same pvc name.

## HOW?
It's simple (not really). First, the script selects the workload that is attached to a pvc, scales it to zero, create a temporary pvc, copy data over, deleting the old pvc, re-creating it and finally migrate data from the temporary to the new pvc.

## Can I use it?
Well... If you dare.
Maybe first try it with `test-migration.sh`
for real tho:
### BACKUP YOUR DATA!!!!!!
* I'm not responsible for dead clusters, etcd in split-brain, loss of data, thermonuclear war, or you getting fired because you ran this script on the AWS production cluster (but i will admire the courage).
* YOU are choosing to use this tool, and if you point the finger at me for messing up your data, I will laugh at you.