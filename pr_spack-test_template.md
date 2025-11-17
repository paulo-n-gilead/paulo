# PAULO/GL9500-582: spack test py-pyrosetta

- Defined `test_create_pose` at `package.py` 
- Added sample pdb file at `<package_dir>/test/5TJ3.pdb` 
- Added test script `<package_dir>/test/test-pyrosetta.py` 

For testing, run the following command from a spack env with pyrosetta installed: `spack test run py-pyrosetta` 

Sample output:
```bash
ADM_pnarvaez@W2RSCWEBDEVN10:~$ spack env activate -p pyrosetta
[pyrosetta] ADM_pnarvaez@W2RSCWEBDEVN10:~$ spack test run py-pyrosetta
==> Spack test 4rperwq7nco36nnhthvm5bn56mj7ynvm
==> Testing package py-pyrosetta-2024.42-a2567cs
============================== 1 passed of 1 spec ==============================
[pyrosetta] ADM_pnarvaez@W2RSCWEBDEVN10:~$
```
