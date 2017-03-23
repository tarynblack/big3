# This code runs a 3D Helheim simulation, using one of the solver files.
#
# LMK, UW, 10/16/2014

import os, sys, datetime
import argparse
import elmerrunlib

##########
# Inputs #
##########

# Get inputs to file
parser = argparse.ArgumentParser()
parser.add_argument("-glacier",dest="glacier",required = True, 
        help = "Name of glacier (Kanger or Helheim)")
parser.add_argument("-mesh", dest="mesh", required = True,
        help = "Name of mesh directory") 
parser.add_argument("-sif",dest="solverfile",required = True, 
        help = "SIF file to run")
parser.add_argument("-front", dest="frontbc", required = False,default='pressure',
        help = "Calving front boundary condition (velocity or pressure).") 
parser.add_argument("-n", dest="n", required = True,
        help = "Number of partitions.")
parser.add_argument("-extrude", dest="extrude", type=int,required = False,\
       default=10,help = "Number of extrusion levels.")
parser.add_argument("-restartsolverfile",dest="restartfile",required = False,\
       default="none",help = "Name of restart solver file (if applicable).")
parser.add_argument("-restartposition",dest="restartposition",required = False,\
       default=0,type=int,help = "Restart position in results file (if applicable).")
parser.add_argument("-temperature",dest="temperature",required  = False,\
       default=-10.0,help = "Use modeled or constant temperature (-10.0 deg C).") 
parser.add_argument("-nt",dest="nt",required  = False,type=str,\
       default='10',help = "Number of timesteps (10).") 
parser.add_argument("-dt",dest="dt",required  = False,type=str,\
       default='1/365.25',help = "Timestep size (1/365.25, i.e., 1 day).") 


args, _ = parser.parse_known_args(sys.argv)

RES = args.mesh
partitions = str(args.n)
extrude = str(args.extrude)
frontbc = str(args.frontbc)
solverfile_in = args.solverfile
glacier = args.glacier
restartfile = args.restartfile
restartposition = args.restartposition
temperature = args.temperature
dt = args.dt
nt = args.nt

# Directories
DIRS=os.path.join(os.getenv("CODE_HOME"),"big3/modeling/solverfiles/SSA/")
DIRM=os.path.join(os.getenv("MODEL_HOME"),glacier+"/3D/"+RES+"/")
DIRR=os.path.join(DIRM+"mesh2d/simulation/")
inputs=os.path.join(DIRM+"/inputs/")

# Check that solver file exists and remove the '.sif' at the end, if it's present
if solverfile_in.endswith('.sif'):
  solverfile_in = solverfile_in[0:-4]
if not(os.path.exists(DIRS+solverfile_in+'.sif')):
  sys.exit('No solverfile with name '+solverfile_in+'.sif')

# Grab boundary condition for front -- it will be different if we are using an actual
# terminus position (neumann, pressure BC) or an outflow boundary (dirichlet, velocity BC)
if (frontbc == 'neumann') or (frontbc == 'pressure'):
  frontbc_text ="""
  Flow Force BC = Logical True
  External Pressure = Variable Coordinate 3 !we are in MPa units
  Real MATC "-1.0*waterpressure(tx)*1.0E-06" """
elif (frontbc == 'dirichlet') or (frontbc == 'velocity'):
  frontbc_text = """
  Velocity 1 = Variable Coordinate 1
    Real procedure "USF_Init.so" "UWa"
  Velocity 2 = Variable Coordinate 1
    Real procedure "USF_Init.so" "VWa"""
else:
  sys.exit("Unknown BC for front of glacier.")

if temperature == 'model':
  temperature_text="""
  Constant Temperature = Variable Coordinate 1, Coordinate 2
    Real Procedure "USF_Init.so" "ModelTemperature" """
else:
  try:
    float(temperature)
    temperature_text="""
  Constant Temperature = Real """+str(temperature)
  except:
    sys.exit("Unknown temperature of "+temperature)

###################################
# Change mesh file in solver file #
###################################

# Get current date
now = datetime.datetime.now()
date = '{0}{1:02.0f}{2:02.0f}'.format((now.year),(now.month),(now.day))
restartposition = 0
 
os.chdir(DIRM)
fid1 = open(DIRS+solverfile_in+'.sif', 'r')
solverfile_out = solverfile_in+'_'+date
fid2 = open(DIRM+solverfile_out+'.sif', 'w')

lines=fid1.read()
lines=lines.replace('{Extrude}', '{0}'.format(extrude))
lines=lines.replace('{FrontBC}', '{0}'.format(frontbc_text))
lines=lines.replace('{Temperature}', '{0}'.format(temperature_text))
lines=lines.replace('{TimeStepSize}', '$({0})'.format(dt))
lines=lines.replace('{TimeSteps}', '{0}'.format(nt))

fid2.write(lines)
fid1.close()
fid2.close()
del fid1, fid2

###################
# Run Elmersolver #
###################

returncode = elmerrunlib.run_elmer(DIRM+solverfile_out+'.sif',n=partitions)