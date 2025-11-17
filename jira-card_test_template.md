**As a QA**

I need to define a default smoke/self test that ensures the spack package **py-pyrosetaa** is properly installed and provides basic functionality.
In this case, running `python test-pyrosetta.py` which script crteates a basic POSE classe from a [PDB file](https://files.rcsb.org/download/5TJ3.pdb)

**Acceptance Criteria**

Run `spack test run py-pyrosetta` while the proper spack env is active (for module availability) completes successfully if sample code returns 0.

Testing methodology, assuming a spack env named pyrosetta with pyrosetta already installed.
```bash
ADM_pnarvaez@W2RSCWEBDEVN10:~$ spack env activate -p pyrosetta
[pyrosetta] ADM_pnarvaez@W2RSCWEBDEVN10:~$ spack test run py-pyrosetta
==> Spack test 4rperwq7nco36nnhthvm5bn56mj7ynvm
==> Testing package py-pyrosetta-2024.42-a2567cs
============================== 1 passed of 1 spec ==============================
[pyrosetta] ADM_pnarvaez@W2RSCWEBDEVN10:~$
```


**References (optional)**

https://spack.readthedocs.io/en/v0.22.2/packaging_guide.html#cmd-spack-test  
https://rosettacommons.github.io/PyRosetta.notebooks/

**Checklist**

Test method definition at package.py