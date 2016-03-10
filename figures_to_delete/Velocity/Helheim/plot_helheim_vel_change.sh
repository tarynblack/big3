#Plot a location map for Helheim Glacier
#Last edited: 06/05/2014, LMK, UW

gmtset FONT_LABEL 9
gmtset FONT_ANNOT_PRIMARY 9
gmtset PS_MEDIA letter
gmtset MAP_ANNOT_ORTHO ver_text
gmtset MAP_FRAME_TYPE plain
gmtset COLOR_BACKGROUND 127.5
gmtset COLOR_FOREGROUND 255/0/0


FILE=helheim_vel.ps

R=-R288000/314000/-2583000/-2559000
#R=-R278000/315000/-2600000/-2550000
J=-Jx1:400000
B=-B10000000m10000000m10000000

#IMAGE=$HOME/Data/Mosaics/Helheim/mosaicHelheim.2013-062.148.31711_1-20mgeo.tif
IMAGE=$HOME/Data/Mosaics/Greenland/mosaic100m.00-01geo.grd

COAST=$HOME/Data/Shape_files/greenland_coast_polar.txt
GLACIER=$HOME/Dropbox/Code/Solver_files/3D/Helheim/Inputs/mesh_extent.dat
FLOWLINE=$HOME/Data/Shape_files/Glaciers/Flowlines/Helheim/helheim_flowline.dat
HOLE1=$HOME/Dropbox/Code/Solver_files/3D/Helheim/Inputs/mesh_hole1.dat
HOLE2=$HOME/Dropbox/Code/Solver_files/3D/Helheim/Inputs/mesh_hole2.dat

#Velocity

#2 km retreat during stability
DIR=$HOME/Data/Velocity/TSX/Helheim/Outputs/
DATA1=$DIR/vel_track-31544.txt 
DATA2=$DIR/vel_track-32713.txt 
RETREAT=$HOME/Data/Shape_files/Retreat_area/retreat_2013day51_to_2013day128.dat

#5 l, retreat during 2001-2006
#DIR=$HOME/Data/Velocity/RADARSAT/Helheim/Outputs/
#DATA1=$DIR/vel_winter00-01.txt 
#DATA2=$DIR/vel_winter05-06.txt 
#RETREAT=$HOME/Data/Shape_files/Retreat_area/retreat_wint01_to_wint05.dat

#Get flowline coordinates
awk '{print $2,$3}' $FLOWLINE > temp2.txt

#Grid file, if needed
awk '{print $1,$2,$3}' $DATA1 > $DIR/temp.txt
xyz2grd $DIR/temp.txt -Gvel1.grd -NNaN -I100 $R
rm $DIR/temp.txt

awk '{print $1,$2,$3}' $DATA2 > $DIR/temp.txt
xyz2grd $DIR/temp.txt -Gvel2.grd -NNaN -I100 $R
rm $DIR/temp.txt

grdmask $HOLE1 -Ghole1.grd $R -I100 -N1/1/NaN
grdmask $HOLE2 -Ghole2.grd $R -I100 -N1/1/NaN
grdmask $GLACIER -Gextent.grd $R -I100 -NNan/1/1
grdmath hole2.grd hole1.grd extent.grd MUL MUL = mask.grd
grdmath vel2.grd vel1.grd SUB = vel3.grd
grdmath vel3.grd ABS = vel4.grd
grdmath vel4.grd mask.grd MUL = vel4.grd
grdmath vel4.grd 1000 DIV = vel5.grd


makecpt -Cgray -T0/255/1 -Z > grayscale.cpt
makecpt -Cseis -T0/3/0.1 -I -Z > velocity.cpt

psbasemap $J $R $B -P -K -V > $FILE
grdimage $IMAGE  -Cgrayscale.cpt $R $J -O -K -V >> $FILE
grdimage vel5.grd -Cvelocity.cpt $R $J -Q -O -K -V >> $FILE
psxy $GLACIER $HOLE1 $HOLE2 $R $J -L -O -K -V >> $FILE
psxy $FLOWLINE $R $J -W1p -K -O  -V >> $FILE
psxy $RETREAT $R $J -W1p -L -Gp600/8 -K -O -V >> $FILE


#psxy $R $J -O -K -L -W0.5p -G255/255/255 <<END>> $FILE
#300500 -2574500
#306500 -2574500
#306500 -2572000
#300500 -2572000
#END

psxy $R $J -O -K -L -W0.5p -G255/255/255 <<END>> $FILE
313400 -2559500
313400 -2568700
305000 -2568700
305000 -2559500
END

#Scale bars
psscale -D2.09i/2.08i/0.7i/0.1ih -Cvelocity.cpt -B0::/:: -O -K -V >> $FILE
psxy $R $J -O -K -W1p <<END>> $FILE 
306800	-2566500 
306800	-2566100 
311800	-2566100 
311800	-2566500 
END

psxy $R $J -O -K -Sc0.15c -G255/255/255 -W <<END>> $FILE 
308068.140459 -2577500.18262
303071.264922 -2577411.6871
298820.865145 -2575260.75625
296554.766007 -2570828.61875
293749.968209 -2566725.38141
290206.375958 -2563197.34722
END

psxy $R $J -O -K -W1p -G255/255/255 <<END>> $FILE 
309200 -2562900
309200 -2561800
END

pstext $R $J -O <<END>> $FILE
#290500 -2567800 10 1 1 TL a
305400  -2560000 8 0 0 TL Velocity change
306500  -2566700 8 0 0 TL 0
311500  -2566700 8 0 0 TL 5
308500  -2567200 9 0 0 TL km
308500  -2563200 8 0 0 TL 1.5
312400  -2563200 8 0 0 TL 3
308000  -2564200 9 0 0 TL km/yr
305500  -2563200 8 0 0 TL 0
305073.776937 -2578289.20561 9 0 0 TL 0 km
289749.968209 -2566725.38141 9 0 0 TL 20 km
END

#ps2pdf helheim_vel.ps helheim_vel.pdf
#ps2raster -A -Tf -E300 helheim_map.ps
rm vel3.grd vel1.grd vel2.grd gmt* temp2.txt

ps2raster -Tf helheim_vel.ps