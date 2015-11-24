import os
import sys
import numpy as np
sys.path.append(os.path.join(os.getenv("CODE_HOME"),"Util/Modules"))
sys.path.append(os.path.join(os.getenv("CODE_HOME"),"BigThreeGlaciers/Tools"))
import velocity, icefronts, bed, glacier_flowline, elevation, fluxgate, flotation
import matplotlib.pyplot as plt
import matplotlib, geotiff, fracyear, dem_shading, icemask, glacier_extent
from matplotlib.ticker import AutoMinorLocator
import scipy.signal as signal
import pylab
import matplotlib.cm as cmx
import matplotlib.colors as colors


##########
# Inputs #
##########

# Get arguments
args = sys.argv
glacier = args[1][:] # Options: Kanger, Helheim

time1 = 2008.
time2 = 2016.

# Map extent
if glacier == 'Kanger':
  xmin = 468000.
  xmax = 498000.
  ymin = -2299000.
  ymax = -2264000.
elif glacier == 'Helheim':
  xmin = 283000.
  xmax = 313000.
  ymin = -2587000.
  ymax = -2552000.

# Image for plotting
if glacier == "Helheim":
  imagetime = fracyear.date_to_fracyear(2014,7,4)
  ximage,yimage,image = geotiff.readrgb(os.path.join(os.getenv("DATA_HOME"),"Imagery/Landsat/Helheim/TIF/20140704140535_LC82330132014185LGN00.tif"))
elif glacier == "Kanger":
  imagetime = fracyear.date_to_fracyear(2014,7,6)
  ximage,yimage,image = geotiff.readrgb(os.path.join(os.getenv("DATA_HOME"),"Imagery/Landsat/Kanger/TIF/20140706135251_LC82310122014187LGN00.tif"))


# Load bed
xb,yb,zb = bed.morlighem_grid(xmin,xmax,ymin,ymax,verticaldatum='geoid')
#xb,yb,zb = bed.smith_grid(glacier,xmin,xmax,ymin,ymax,verticaldatum='geoid',model='aniso',smoothing=4,grid='structured')

# Load velocity variability
xvel,yvel,velall,velmean,velstd,velcount,veltime = velocity.variability(glacier,time1,time2)

# Load elevation variability
if glacier == 'Helheim':
  xzs,yzs,zsall,zsmean,zsstd,zscount,zstime = elevation.variability(glacier,time1,time2,data='TDX')
elif glacier == 'Kanger':
  xzs,yzs,zsall,zsmean,zsstd,zscount,zstime = elevation.variability(glacier,time1,time2)

# Find flotation conditions
xwv,ywv,zwv,timewv = elevation.dem_grid(glacier,xmin,xmax,ymin,ymax,years='all',resolution=32,verticaldatum='geoid')
xf,yf,zabovefloat = flotation.extent(xwv,ywv,zwv,timewv,glacier,rho_i=917.0,rho_sw=1020.0,bedsource='cresis',verticaldatum='geoid')

cutoff = 5.
floatcond = np.zeros(len(xf))
floatcond[:] = float('nan')
for i in range(0,len(xf)):
  if np.nanmin(zabovefloat[i,:]) > cutoff:
    floatcond[i] = 1 #grounded
  elif np.nanmax(zabovefloat[i,:]) < -1*cutoff:
    floatcond[i] = -1 #floating
  elif (np.nanmax(zabovefloat[i,:]) > -1*cutoff) or (np.nanmin(zabovefloat[i,:]) < cutoff):
    floatcond[i] = 0 #changing basal conditions

velstd_high = np.array(velstd)
velstd_high[velcount < 0.5*len(veltime)] = float('nan')

fig = plt.figure(figsize=(7.5,2.4))
matplotlib.rc('font',family='Arial')
gs = matplotlib.gridspec.GridSpec(1,4)

plt.subplot(gs[0])
ax1 = plt.gca()
plt.imshow(image[:,:,0],extent=[np.min(ximage),np.max(ximage),np.min(yimage),np.max(yimage)],cmap='Greys_r',origin='lower',clim=[0,0.6])
p=plt.imshow(zb/1.0e3,extent=[np.min(xb),np.max(xb),np.min(yb),np.max(yb)],origin='lower',cmap='RdBu_r',clim=[-1,1])
plt.contour(velstd_high*2/1.0e3,levels=[0.1],extent=[np.min(xvel),np.max(xvel),np.min(yvel),np.max(yvel)],origin='lower',colors='k',lw=2,zorder=2)
ax1.axes.set_xlim([xmin,xmax])
ax1.axes.set_ylim([ymin,ymax])
ax1.set_xticks([])
ax1.set_yticks([])
xmin1,xmax1 = plt.xlim()
ymin1,ymax1 = plt.ylim()
path = matplotlib.path.Path([[0.49*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1],
  			[0.49*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1]])
patch = matplotlib.patches.PathPatch(path,edgecolor='k',facecolor='w',lw=1,zorder=3)
ax1.add_patch(patch)
cbaxes = fig.add_axes([0.15, 0.86, 0.085, 0.02]) 
cb = plt.colorbar(p,cax=cbaxes,orientation='horizontal',ticks=[-1,0,1]) 
cb.set_label('Bed elevation \n (km asl)',size=9,fontname='arial')
cb.ax.tick_params(labelsize=9)
#ax1.plot([xmin+0.61*(xmax-xmin),xmin+0.61*(xmax-xmin)+5e3],[ymin+0.73*(ymax-ymin),ymin+0.73*(ymax-ymin)],'k',linewidth=1.5)
#ax1.plot([xmin+0.61*(xmax-xmin),xmin+0.61*(xmax-xmin)],[ymin+0.73*(ymax-ymin),ymin+0.71*(ymax-ymin)],'k',linewidth=1.5)
#ax1.plot([xmin+0.61*(xmax-xmin)+5e3,xmin+0.61*(xmax-xmin)+5e3],[ymin+0.73*(ymax-ymin),ymin+0.71*(ymax-ymin)],'k',linewidth=1.5)
#ax1.text(xmin+0.64*(xmax-xmin)+5e3,ymin+0.7*(ymax-ymin),'5 km',fontsize=10)

plt.subplot(gs[1])
ax2 = plt.gca()
ax2.axes.autoscale(False)
plt.imshow(image[:,:,0],extent=[np.min(ximage),np.max(ximage),np.min(yimage),np.max(yimage)],cmap='Greys_r',origin='lower',clim=[0,0.6])
p=plt.imshow(velstd_high*2/1.0e3,clim=[0,1],extent=[np.min(xvel),np.max(xvel),np.min(yvel),np.max(yvel)],origin='lower',cmap='jet')
plt.contour(velstd_high*2/1.0e3,levels=[0.1],extent=[np.min(xvel),np.max(xvel),np.min(yvel),np.max(yvel)],origin='lower',colors='k',lw=2,zorder=2)
ax2.set_xticks([])
ax2.set_yticks([])
ax2.axes.set_xlim([xmin,xmax])
ax2.axes.set_ylim([ymin,ymax])
xmin1,xmax1 = plt.xlim()
ymin1,ymax1 = plt.ylim()
path = matplotlib.path.Path([[0.49*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1],
  			[0.49*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1]])
patch = matplotlib.patches.PathPatch(path,edgecolor='k',facecolor='w',lw=1,zorder=3)
ax2.add_patch(patch)
cbaxes = fig.add_axes([0.39, 0.86, 0.085, 0.02]) 
cb = plt.colorbar(p,cax=cbaxes,orientation='horizontal',ticks=[0,0.5,1]) 
cb.set_label(r"Velocity 2-$\mathrm{\sigma}$",size=9,fontname='arial')
cb.ax.tick_params(labelsize=9)

plt.subplot(gs[2])
ax3 = plt.gca()
ax3.axes.autoscale(False)
plt.imshow(image[:,:,0],extent=[np.min(ximage),np.max(ximage),np.min(yimage),np.max(yimage)],cmap='Greys_r',origin='lower',clim=[0,0.6])
zsstd_high = np.array(zsstd)
zsstd_high[zscount < 2] = float('nan')
p=plt.imshow(zsstd_high*2,clim=[0,20],extent=[np.min(xzs),np.max(xzs),np.min(yzs),np.max(yzs)],origin='lower',cmap='jet')
plt.contour(velstd_high*2/1.0e3,levels=[0.1],extent=[np.min(xvel),np.max(xvel),np.min(yvel),np.max(yvel)],origin='lower',colors='k',lw=2,zorder=2)
#plt.contour(zsstd_high*1.96,levels=[5],extent=[np.min(xvel),np.max(xvel),np.min(yvel),np.max(yvel)],origin='lower',colors='k',lw=2)
ax3.set_xticks([])
ax3.set_yticks([])
ax3.axes.set_xlim([xmin,xmax])
ax3.axes.set_ylim([ymin,ymax])
xmin1,xmax1 = plt.xlim()
ymin1,ymax1 = plt.ylim()
path = matplotlib.path.Path([[0.49*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1],
  			[0.49*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1]])
patch = matplotlib.patches.PathPatch(path,edgecolor='k',facecolor='w',lw=1,zorder=3)
ax3.add_patch(patch)
cbaxes = fig.add_axes([0.625, 0.86, 0.09, 0.02]) 
cb = plt.colorbar(p,cax=cbaxes,orientation='horizontal',ticks=[0,10,20]) 
cb.set_label(r'Elevation 2-$\sigma$',size=9,fontname='arial')
cb.ax.tick_params(labelsize=9)


plt.subplot(gs[3])
ax3 = plt.gca()
ax3.axes.autoscale(False)
plt.imshow(image[:,:,0],extent=[np.min(ximage),np.max(ximage),np.min(yimage),np.max(yimage)],cmap='Greys_r',origin='lower',clim=[0,0.6])
plt.plot(0,0,'r.',label='Grounded',markersize=5)
plt.plot(0,0,'b.',label='Floating',markersize=5)
plt.plot(0,0,'k.',label='Changing',markersize=5)
ind = np.where(floatcond == 1)
plt.plot(xf[ind],yf[ind],'r.',lw=0,markersize=2)
ind = np.where(floatcond == -1)
plt.plot(xf[ind],yf[ind],'b.',lw=0,markersize=2)
ind = np.where(floatcond == 0)
plt.plot(xf[ind],yf[ind],'k.',lw=0,markersize=2)
#p=plt.imshow(zsstd_high*2,clim=[0,20],extent=[np.min(xzs),np.max(xzs),np.min(yzs),np.max(yzs)],origin='lower',cmap='jet')
#plt.contour(zsstd_high*1.96,levels=[5],extent=[np.min(xvel),np.max(xvel),np.min(yvel),np.max(yvel)],origin='lower',colors='k',lw=2)
ax3.set_xticks([])
ax3.set_yticks([])
ax3.axes.set_xlim([xmin,xmax])
ax3.axes.set_ylim([ymin,ymax])
xmin1,xmax1 = plt.xlim()
ymin1,ymax1 = plt.ylim()
path = matplotlib.path.Path([[0.54*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1],
  			[0.54*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1]])
patch = matplotlib.patches.PathPatch(path,edgecolor='k',facecolor='w',lw=1,zorder=3)
ax3.add_patch(patch)
plt.legend(loc=1,numpoints=1,frameon=False,labelspacing=0.07,handletextpad=0.5,handlelength=0.2,fontsize=9)
ax3.plot([xmin1+0.6*(xmax1-xmin1),xmin+0.6*(xmax1-xmin1)+5e3],[ymin1+0.73*(ymax1-ymin1),ymin1+0.73*(ymax1-ymin1)],'k',linewidth=1.5,zorder=5)
ax3.plot([xmin1+0.6*(xmax1-xmin1),xmin1+0.6*(xmax1-xmin1)],[ymin1+0.73*(ymax1-ymin1),ymin1+0.71*(ymax1-ymin1)],'k',linewidth=1.5,zorder=5)
ax3.plot([xmin1+0.6*(xmax1-xmin1)+5e3,xmin1+0.6*(xmax1-xmin1)+5e3],[ymin1+0.73*(ymax1-ymin1),ymin1+0.71*(ymax1-ymin1)],'k',linewidth=1.5,zorder=5)
ax3.text(xmin1+0.64*(xmax1-xmin1)+5e3,ymin1+0.7*(ymax1-ymin1),'5 km',fontsize=9,fontname='arial')

plt.tight_layout()
plt.subplots_adjust(hspace=0.05,wspace=0.05)
plt.savefig(os.path.join(os.getenv("HOME"),"Bigtmp/"+glacier+"_variability.pdf"),FORMAT='PDF',dpi=200)
plt.close()

zstrend = np.zeros_like(zsstd)
zstrend[:,:] = float('nan')
for j in range(0,len(yzs)):
  for i in range(0,len(xzs)):
    nonnan = np.where(~(np.isnan(zsall[j,i,:])))[0]
    if (len(nonnan) > 3) and np.max(zstime[nonnan]) > 2014. and np.min(zstime[nonnan]) < 2012.:
      p = np.polyfit(zstime[nonnan],zsall[j,i,nonnan],1)
      zstrend[j,i] = p[0]

veltrend = np.zeros_like(velstd)
veltrend[:,:] = float('nan')
for j in range(0,len(yvel)):
  for i in range(0,len(xvel)):
    nonnan = np.where(~(np.isnan(velall[j,i,:])))[0]
    if (len(nonnan) > 0.5*len(veltime)):
      p = np.polyfit(veltime[nonnan,0],velall[j,i,nonnan],1)
      veltrend[j,i] = p[0]

fig = plt.figure(figsize=(4,2.4))
matplotlib.rc('font',family='Arial')
gs = matplotlib.gridspec.GridSpec(1,2)

plt.subplot(gs[0])
ax1 = plt.gca()
plt.imshow(image[:,:,0],extent=[np.min(ximage),np.max(ximage),np.min(yimage),np.max(yimage)],cmap='Greys_r',origin='lower',clim=[0,0.6])
p=plt.imshow(veltrend,extent=[np.min(xvel),np.max(xvel),np.min(yvel),np.max(yvel)],origin='lower',clim=[-100,5])
ax1.axes.set_xlim([xmin,xmax])
ax1.axes.set_ylim([ymin,ymax])
ax1.set_xticks([])
ax1.set_yticks([])
xmin1,xmax1 = plt.xlim()
ymin1,ymax1 = plt.ylim()
path = matplotlib.path.Path([[0.49*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1],
  			[0.49*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1]])
patch = matplotlib.patches.PathPatch(path,edgecolor='k',facecolor='w',lw=1,zorder=3)
ax1.add_patch(patch)
cbaxes = fig.add_axes([0.3, 0.86, 0.16, 0.02]) 
cb = plt.colorbar(p,cax=cbaxes,orientation='horizontal',ticks=[-100,-50,0]) 
cb.set_label('dv/dt \n (m/yr-2)',size=9,fontname='arial')
cb.ax.tick_params(labelsize=9)

plt.subplot(gs[1])
ax2 = plt.gca()
plt.imshow(image[:,:,0],extent=[np.min(ximage),np.max(ximage),np.min(yimage),np.max(yimage)],cmap='Greys_r',origin='lower',clim=[0,0.6])
p=plt.imshow(zstrend,clim=[-10,5],extent=[np.min(xzs),np.max(xzs),np.min(yzs),np.max(yzs)],origin='lower',cmap='jet')
ax2.set_xticks([])
ax2.set_yticks([])
ax2.axes.set_xlim([xmin,xmax])
ax2.axes.set_ylim([ymin,ymax])
xmin1,xmax1 = plt.xlim()
ymin1,ymax1 = plt.ylim()
path = matplotlib.path.Path([[0.49*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.98*(ymax1-ymin1)+ymin1],
  			[0.98*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1],
  			[0.49*(xmax1-xmin1)+xmin,0.66*(ymax1-ymin1)+ymin1]])
patch = matplotlib.patches.PathPatch(path,edgecolor='k',facecolor='w',lw=1,zorder=3)
ax2.add_patch(patch)
cbaxes = fig.add_axes([0.76, 0.86, 0.16, 0.02]) 
cb = plt.colorbar(p,cax=cbaxes,orientation='horizontal',ticks=[-10,-5,0,5]) 
cb.set_label("dH/dt \n (m/yr)",size=9,fontname='arial')
cb.ax.tick_params(labelsize=9)

plt.tight_layout()
plt.subplots_adjust(hspace=0.05,wspace=0.05)
plt.savefig(os.path.join(os.getenv("HOME"),"Bigtmp/"+glacier+"_trends.pdf"),FORMAT='PDF',dpi=200)
plt.close()

