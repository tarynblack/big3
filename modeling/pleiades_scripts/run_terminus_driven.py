import subprocess
import time
import os

glacier = 'Helheim'

# Mesh characteristics and geometry
meshshp = 'glacier_extent_terminus_nofront'
extrude = 12
bname = 'smith'
bmodel = 'aniso'
bsmooth = '5'
bottomsurface = 'iceshelf'
temperature = 'model' #'-10.0' #'model'
#lc = '500 1000 1000 2000'
lc = '150 400 700 1000'

# Info for steady state simulation to relax model
steadystate_nt = 105 # 2 years

# Info terminus driven model
date1 = '20120908'
date2 = '20160615' #20160616
dt_relax = '7/365.25'
dt_terminus = '1/365.25'
timeseries = 'True'
slidinglaw = 'linear'#'linear' #'weertman'

# Inversion options
method = 'adjoint'
regpar = '3e11'
frontBC = 'pressure'
slipcoefficient = '1.0E-1'
sidewallBC = 'friction' # or velocity or friction

runname = 'TD_'+date1+'_'+date2+'_modelT_linearB_1E1_pressure'

# Options for PBS submission
queue = 'long'
model = 'has'
nparts = 96
ncpus = 24
runtime_relax = '10:00:00'
runtime_inversion = '8:00:00'
runtime_terminus = '50:00:00'

# Mesh directory
dir = "/nobackupp8/lkehrl/Models/"+glacier+"/3D/"+runname+"/"

#################
# Create meshes #
#################
command = "python /u/lkehrl/Code/big3/modeling/meshing/"+\
          "mesh_3d.py "+"-glacier {0} -mesh {1}".format(glacier,meshshp)+\
          " -bname {0} -bmodel {1} -bsmooth {2}".format(bname,bmodel,bsmooth)+\
          " -zb {0} -temperature {1} -lc {2}".format(bottomsurface,temperature,lc)+\
          " -timeseries {0} -dt {1} -d {2}".format(timeseries,dt_terminus,date1)+\
          " -d2 {0} -n {1} -output {2} ".format(date2,nparts,runname)            
print command
os.system(command)

###############################
# Create inversion PBS script #
###############################
command = "python /u/lkehrl/Code/big3/modeling/inversions/"+\
          "inversion_3d.py -glacier {0} -mesh {1}".format(glacier,runname)+\
          " -method {0} -regpar {1} -extrude {2}".format(method,regpar,extrude)+\
          " -front {0} -n {1} -sidewall {2}".format(frontBC,nparts,sidewallBC)+\
          " -slipcoefficient {0} -temperature {1} -itmax 200".format(slipcoefficient, temperature)

job_name = glacier+"_"+runname+"_inversion"
processors =     processors = "select={0}:ncpus={1}:mpiprocs={2}:model={3}".format(nparts/ncpus,ncpus,ncpus,model)

job_string = """
#PBS -S /bin/bash
#PBS -M kehrl@uw.edu
#PBS -m abe
#PBS -N %s
#PBS -l walltime=%s
#PBS -l %s
#PBS -o %s
#PBS -e %s
source /u/lkehrl/.profile
source /u/lkehrl/.bashrc_pleiades_haswell_sles12
cd %s
%s""" % (job_name, runtime_inversion, processors, dir+"PBS_inversion.out",dir+"PBS_inversion.err",dir,command)

print command  
os.chdir(dir)
fid = open("PBS_inversion.pbs","w")
fid.write(job_string)
fid.close()

try:
  subprocess.call(['qsub','PBS_inversion.pbs'])
except:
  print "Couldn't submit inversion"

#####################################
# Create steadystate PBS job script #
#####################################

command = "python /u/lkehrl/Code/big3/modeling/simulations/"+\
          "simulation_3d.py -glacier {0} -sif iceshelf.sif".format(glacier)+\
          " -mesh {0} -extrude {1} -n {2}".format(runname,extrude,nparts)+\
          " -dt {0} -nt {1} -temperature {2}".format(dt_relax,steadystate_nt,temperature)+\
          " -slipcoefficient {0} -slidinglaw {1}".format(slipcoefficient,slidinglaw)

job_name = glacier+"_"+runname+"_relaxation"
processors = "select={0}:ncpus={1}:mpiprocs={2}:model={3}".format(nparts/ncpus,ncpus,ncpus,model)

job_string = """
#PBS -S /bin/bash
#PBS -M kehrl@uw.edu
#PBS -m abe
#PBS -N %s
#PBS -l walltime=%s
#PBS -l %s
#PBS -o %s
#PBS -e %s
source /u/lkehrl/.profile
source /u/lkehrl/.bashrc_pleiades_haswell_sles12
cd %s
%s""" % (job_name, runtime_relax, processors, dir+"PBS_relaxation.out",dir+"PBS_relaxation.err",dir,command)

print command
os.chdir(dir)
fid = open("PBS_relaxation.pbs","w")
fid.write(job_string)
fid.close()

#########################################
# Create terminus-driven PBS job script #
#########################################

# Get number of timesteps from mesh files
nt = 0
files = os.listdir(dir)
for file in files:
  if file.startswith('mesh') and not(file.endswith('.msh')) and not(file.endswith('.geo')) and not(file.endswith('tar.gz')) and not(file.endswith('mesh2d')) and not(file.endswith('.txt')):
    if int(file[-4:]) > nt:
      nt = int(file[-4:])
  elif file.startswith('mesh') and file.endswith('tar.gz') and not(file.startswith('mesh_')):
    if int(file[-11:-7]) > nt:
      nt = int(file[-11:-7])
   
command = "python /u/lkehrl/Code/big3/modeling/simulations/"+\
          "simulation_3d.py -glacier {0} -sif terminusdriven_advance.sif".format(glacier)+\
          " -mesh {0} -extrude {1} -n {2}".format(runname,extrude,nparts)+\
          " -dt {0} -nt {1} -temperature {2}".format(dt_terminus,nt,temperature)+\
          " -slipcoefficient {0} -slidinglaw {1}".format(slipcoefficient,slidinglaw)

job_name = glacier+"_"+runname+"_terminusdriven"
processors = "select={0}:ncpus={1}:mpiprocs={2}:model={3}".format(nparts/ncpus,ncpus,ncpus,model)

job_string = """
#PBS -S /bin/bash
#PBS -M kehrl@uw.edu
#PBS -m abe
#PBS -N %s
#PBS -l walltime=%s
#PBS -l %s
#PBS -o %s
#PBS -e %s
source /u/lkehrl/.profile
source /u/lkehrl/.bashrc_pleiades_haswell_sles12
cd %s
%s""" % (job_name, runtime_terminus, processors, dir+"PBS_terminusdriven.out",dir+"PBS_terminusdriven.err",dir,command)

print command
os.chdir(dir)
fid = open("PBS_terminusdriven.pbs","w")
fid.write(job_string)
fid.close() 
