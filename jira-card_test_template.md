**As a QA**

I need to define a default smoke/self test that ensures the spack package **easel** is properly installed and provides basic functionality.
In this case, calling `easel --version`

**Context (optional)**

Latest definition points to simple binary test as enough.

**Acceptance Criteria**

Running `spack test run easel` on demand passes as the binary exits with code 0.

**References (optional)**

https://spack.readthedocs.io/en/v0.22.2/packaging_guide.html#cmd-spack-test  
https://github.com/EddyRivasLab/easel

**Checklist**

Test method definition at package.py