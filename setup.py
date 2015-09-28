from setuptools import setup

def readme():
    with open('README.md') as f:
        return f.read()

setup(name='floater',
      version='0.1',
      description='Utilities for processing lagrangian float data',
      url='http://github.com/rabernat/floater',
      author='Ryan Abernathey',
      author_email='rpa@ldeo.columbia.edu',
      license='MIT',
      packages=['floater'],
      scripts=['scripts/floater_convert'],
      install_requires=[
          'tables', 'numpy'
      ],
      test_suite = 'nose.collector',
      zip_safe=False)