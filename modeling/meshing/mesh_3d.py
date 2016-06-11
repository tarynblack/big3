# Makes a 3D mesh of Helheim Glacier
# 
# LMK, UW, 06/01/2014
# Last updated 06/14/2014

import os
import shutil
import sys
import vellib, datelib, glaclib, flowparameterlib, meshlib, inverselib, climlib
from subprocess import call
from scipy.interpolate import *
import numpy as np
import argparse


def get_arguments():

  ##########
  # inputs #
  ##########

  # Get inputs to file
  parser = argparse.ArgumentParser()
  parser.add_argument("-glacier",dest="glacier",required = True, 
        help = "Name of glacier (Kanger or Helheim)")
  parser.add_argument("-output", dest="output", required = True,
        help = "Name of output mesh.")
  parser.add_argument("-mesh", dest="meshshp", required = True,
        help = "Name for input shapefile.")
  parser.add_argument("-d", dest="date", required = True,
        help = "Date for mesh.")
  parser.add_argument("-n", dest="n", required = True,
        help = "Number of partitions.")
  parser.add_argument("-bname", dest="bedname", required = False,default='morlighem',
        help = "Name of bed file (smith,morlighem,cresis).")
  parser.add_argument("-bmodel", dest="bedmodel", required = False,default='aniso',
        help = "Type of bed (aniso,iso).")
  parser.add_argument("-bsmooth", dest="bedsmooth", type=int,required = False,
			  default=4,help = "Smoothness of bed (1-8).")
  parser.add_argument("-dx", dest="dx", required = False,default='none',
			  help = "Grid size for gridded products.")
  parser.add_argument("-lc", dest="lc", type=int,required = False,nargs='+',
			  default=[1000,1000,3000,5000],\
			  help = "Four numbers that define the mesh resolution for grounding-line (1000 m),channels (1000 m),regions near channels (3000 m), and entire mesh (5000 m).")

  # Get arguments
  args, _ = parser.parse_known_args(sys.argv)

  return args

def main():

  args = get_arguments()

  date = args.date
  partitions = args.n
  bedname = args.bedname
  bedmodel = args.bedmodel
  bedsmoothing = args.bedsmooth
  outputmeshname = args.output
  meshshp = args.meshshp
  glacier = args.glacier
  dx = args.dx

  # Mesh refinement
  lc3,lc2,lc4,lc1 = args.lc

  # Directories
  DIRM = os.path.join(os.getenv("MODEL_HOME"),glacier+"/3D/"+outputmeshname+"/")
  DIRX = os.path.join(os.getenv("DATA_HOME"),"ShapeFiles/Glaciers/3D/"+glacier+"/")
  inputs = os.path.join(DIRM+"inputs/")

  # Make mesh directories
  if not(os.path.isdir(DIRM)):
    os.makedirs(DIRM)
    os.makedirs(DIRM+"/inputs")

  # Densities for finding floating ice
  rho_i = 917.0
  rho_sw = 1020.0

  # Time
  time = datelib.date_to_fracyear(int(date[0:4]),int(date[4:6]),int(date[6:8]))

  #################
  # Mesh Geometry #
  #################

  # Mesh exterior
  if meshshp.endswith('nofront'):
    exterior = glaclib.load_extent(glacier,time,nofront_shapefile=meshshp)
  else:
    exterior = meshlib.shp_to_xy(DIRX+meshshp)
  np.savetxt(inputs+"mesh_extent.dat",exterior[:,0:2])

  # Mesh holes
  holes = []
  if os.path.isfile(DIRX+"glacier_hole1.shp"):
    hole1 = meshlib.shp_to_xy(DIRX+"glacier_hole1")
    np.savetxt(inputs+"mesh_hole1.dat",hole1[:,0:2])
    holes.append({'xy': hole1})
  if os.path.isfile(DIRX+"glacier_hole2.shp"):
    hole2 = meshlib.shp_to_xy(DIRX+"glacier_hole2")
    np.savetxt(inputs+"mesh_hole2.dat",hole2[:,0:2])
    holes.append({'xy': hole2})

  # Add locations for refinement
  refine = meshlib.shp_to_xy(DIRX+"refine")

  ###########
  # Outputs #
  ###########

  #Set output name for gmsh file
  file_2d=os.path.join(DIRM+"mesh2d")
  #file_3d=os.path.join(DIRM+"mesh3d")

  ##################################################################
  # Save file with mesh inputs so we know how the mesh was created #
  ##################################################################
  
  fid = open(DIRM+'mesh_info.txt','w')
  fid.write('glacier = {}\n'.format(glacier))
  fid.write('date = {}\n'.format(date))
  fid.write('meshshapefile = {}\n'.format(meshshp))
  fid.write('lc1 = {}\n'.format(lc1))
  fid.write('lc2 = {}\n'.format(lc2))
  fid.write('lc3 = {}\n'.format(lc3))
  fid.write('lc4 = {}\n'.format(lc4))
  fid.write('bed = {}\n'.format(bedname))
  fid.write('bed model = {}\n'.format(bedmodel))
  fid.write('bed smoothness = {}'.format(bedsmoothing))
  
  fid.close()
  
  #############
  # Make mesh #
  #############

  # Gmsh .geo file
  x,y,zbed,zsur,zbot = meshlib.xy_to_gmsh_3d(glacier,date,exterior,holes,refine,DIRM,\
		lc1,lc2,lc3,lc4,bedname,bedmodel,bedsmoothing,rho_i,rho_sw,dx=dx)

  # Create .msh file
  call(["gmsh","-1","-2",file_2d+".geo", "-o",os.path.join(os.getenv("HOME"),\
		file_2d+".msh")])

  # Create elmer mesh
  call(["ElmerGrid","14","2",file_2d+".msh","-autoclean"])

  # Extrude the mesh with ExtrudeMesh
  # call(["ExtrudeMesh",file_2d,file_3d,str(levels),"1","1","0","0","0","0",inputs,"200","2","NaN"])

  # Partition mesh for parallel processing
  os.chdir(DIRM)
  call(["ElmerGrid","2","2","mesh2d","dir","-metis",partitions,"0"])

  # Output as gmsh file so we can look at it
  # call(["ElmerGrid","2","4","Elmer"])

  ##########################################
  # Print out velocity data for inversions #
  ##########################################

  # Output files for velocities in x,y directions (u,v)
  u,v = vellib.inversion_3D(glacier,x,y,time,inputs,dx=dx)

  ###############################################
  # Get surface temperature and geothermal flux #
  ###############################################
  
  xt2m = np.arange(x[0]-1e3,x[-1]+1e3,1e3)
  yt2m = np.arange(y[0]-1e3,y[-1]+1e3,1e3)
  timet2m,t2m = climlib.racmo_interpolate_to_cartesiangrid(xt2m,yt2m,'t2m',epsg=3413,maskvalues='ice',timing='mean')
  #ggrid = bedlib.geothermalflux_grid(xt2m,yt2m,model='davies',method='nearest')

  fidt2m = open(inputs+"t2m.xy","w")
  fidt2m.write('{}\n{}\n'.format(len(xt2m),len(yt2m)))
  #fidgeo = open(inputs+"geothermal.xy","w")
  #fidgeo.write('{}\n{}\n'.format(len(xt2m),len(yt2m)))
  for i in range(0,len(xt2m)):
    for j in range(0,len(yt2m)):
      fidt2m.write('{0} {1} {2}\n'.format(xt2m[i],yt2m[j],t2m[j,i]))
      #fidgeo.write('{0} {1} {2}\n'.format(xt2m[i],yt2m[j],ggrid[j,i]))
  fidt2m.close()
  #fidgeo.close()
  
  del xt2m,yt2m,timet2m,t2m,fidt2m 
  # del fidgeo, ggrid

  #print "Getting flow law parameters...\n"
  #flowA = flowparameterlib.load_kristin(glacier,x,y,type='A',dir=inputs)

  #################################################################
  # Calculate basal sliding speed using SIA for inflow boundaries #
  #################################################################

  print "Calculating basal sliding speed for inflow boundaries and guessing a beta...\n"
  frac = 0.5
  ub,vb,beta = inverselib.guess_beta(x,y,zsur,zbed,u,v,frac)

  # Write out basal velocities and initial guess for beta
  fidub = open(inputs+"ubdem.xy","w")
  fidvb = open(inputs+"vbdem.xy","w")
  fidbeta = open(inputs+"beta0.xy","w")
  fidvb.write('{}\n{}\n'.format(len(x),len(y)))
  fidub.write('{}\n{}\n'.format(len(x),len(y)))
  fidbeta.write('{}\n{}\n'.format(len(x),len(y)))
  for i in range(0,len(x)):
    for j in range(0,len(y)):
      fidub.write('{0} {1} {2}\n'.format(x[i],y[j],ub[j,i]))
      fidvb.write('{0} {1} {2}\n'.format(x[i],y[j],vb[j,i]))
      fidbeta.write('{0} {1} {2}\n'.format(x[i],y[j],beta[j,i]))
  fidub.close()
  fidvb.close()
  fidbeta.close()

  ##############################################################
  # Print out bedrock and surface topographies for elmersolver #
  ##############################################################

  # fid = open(inputs+"mesh_bed.dat","w")
  # fid.write('{}\n'.format(len(nodes)))
  # for i in range(0,len(nodes[:,1])):
  #  fid.write("{} {} {} {} \n".format(nodes[i,0],nodes[i,2],nodes[i,3],nodes[i,4]))
  # fid.close()
  
if __name__ == "__main__":
  main()
