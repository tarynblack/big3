SUBROUTINE ReMesh(Model,Solver,dt,Transient )
!------------------------------------------------------------------------------
   USE CRSMatrix
   USE GeneralUtils
   USE ElementDescription
   USE MeshUtils  
   USE InterpVarToVar
   USE MainUtils
   USE SolverUtils
   USE Geometry

   IMPLICIT NONE
!------------------------------------------------------------------------------
   TYPE(Solver_t) :: Solver
   TYPE(Model_t) :: Model
   REAL(KIND=dp) :: dt
   LOGICAL :: Transient

!------------------------------------------------------------------------------
! Local variables
!------------------------------------------------------------------------------

  TYPE(Mesh_t), POINTER :: OldMesh, NewMesh, FootPrintMesh, ExtrudedMesh
  TYPE(Variable_t), POINTER :: Var, RefVar, OldTopVar, OldBotVar, NewTopVar, NewBotVar, &
      OldGLVar, NewGLVar, TimestepVar, WorkVar
  TYPE(Nodes_t), POINTER :: OldNodes, NewNodes
  TYPE(Matrix_t), POINTER :: StiffMatrix
  TYPE(ValueList_t), POINTER :: Params, Material
  TYPE(Element_t), POINTER :: Element, CurrentElement
  TYPE(Solver_t), POINTER :: PSolver
  INTEGER :: ExtrudeLevels, i, j, k, ierr, n, NodesPerLevel, dim, dummyint, active, &
      Timestep, nxbed, nybed
  INTEGER, POINTER :: OldTopVarPerm(:)=>NULL(), OldTopPerm(:)=>NULL(), OldBotPerm(:)=>NULL(), &
      OldBotVarPerm(:)=>NULL(), TopVarPerm(:)=>NULL(), BotVarPerm(:)=>NULL(), &
      WorkPerm(:), InterpDim(:)=>NULL(), TopPointer(:), BotPointer(:), MidPointer(:)
  INTEGER, ALLOCATABLE :: Columns(:)
  REAL(KIND=dp), POINTER :: TopVarValues(:), BotVarValues(:), WorkReal(:), ForceVector(:)
  CHARACTER(LEN=MAX_NAME_LEN) :: Name, OldMeshName, NewMeshName, SolverName, VarName, &
      TopMaskName, BotMaskName, BotVarName, TopVarName, GLVarName
  REAL(KIND=dp), ALLOCATABLE :: STIFF(:,:), FORCE(:), BedHeight(:), dembed(:,:), &
      xxbed(:),yybed(:)
  LOGICAL :: Boss, Debug, Found, Parallel, FirstTime=.TRUE., DoGL, First
  LOGICAL, POINTER :: UnfoundNodes(:)=>NULL(),OldMaskLogical(:),NewMaskLogical(:)
  REAL(kind=dp) :: global_eps, local_eps, top, bot, x, y, zb
  Real(kind=dp) :: LinearInterp
  
  SAVE :: FirstTime, BotMaskName, TopMaskName
  SAVE :: dembed,xxbed,yybed,nxbed,nybed

  
  Debug = .TRUE.
  
  SolverName = "ReMesh"
  dim = CoordinateSystemDimension()
  Params => Solver % Values
  Parallel = (ParEnv % PEs > 1)
  Boss = (ParEnv % MyPE == 0) .OR. (.NOT. Parallel)
  PSolver => Model % Solver
  
  global_eps = 1.0E-2_dp
  local_eps = 1.0E-2_dp
  
  IF (FirstTime) THEN
    TopMaskName = "Top Surface Mask"
    BotMaskName = "Bottom Surface Mask"
  END IF !FirstTime
  
  ! Get current mesh
  OldMesh => GetMesh()
  OldMeshName = OldMesh % Name
  OldNodes => OldMesh % Nodes

  !----------------------------------------------
  ! Load footprint mesh
  !----------------------------------------------



	TimestepVar => VariableGet( Model % Variables,'Timestep')
	Timestep = TimestepVar % Values(1)
	WRITE (NewMeshName, "(A4,I1)") "mesh", Timestep

  FootPrintMesh => LoadMesh2( Model, NewMeshName, NewMeshName, &
       .FALSE., Parenv % PEs, ParEnv % myPE) ! May need to adjust parameters to account for parallel mesh
  FootPrintMesh % Name = TRIM(NewMeshName //'_footprint')
  FootprintMesh % OutputActive = .TRUE.
  FootprintMesh % Changed = .TRUE.
  
  IF(Parallel) CALL MPI_BARRIER(MPI_COMM_WORLD, ierr)

  !----------------------------------------------
  ! Extrude footprint mesh to z = 0 to 1
  !----------------------------------------------

  ! Extrude new mesh and map coordinates to new mesh
  ExtrudeLevels = GetInteger(Model % Simulation,'Extruded Mesh Levels',Found)
  ExtrudedMesh => NULL()
  IF (Found) THEN
    IF(ExtrudeLevels>1) THEN
      CALL Info(SolverName,'Extruding new mesh',level=4)
      ExtrudedMesh => MeshExtrude(FootprintMesh, ExtrudeLevels-2)
    END IF
  END IF

  IF(Parallel) CALL MPI_BARRIER(MPI_COMM_WORLD, ierr)

  ! Temporarily add basic variables to mesh 
  CALL CopyIntrinsicVars(OldMesh, ExtrudedMesh)

  !-------------------------------------------
  ! Create nodal BC perms for old mesh to make lookup simpler
  !-------------------------------------------
  n = OldMesh % NumberOfNodes
  ALLOCATE( OldTopPerm(n), OldBotPerm(n) )

  !Generate perms to quickly get nodes on each boundary
  CALL MakePermUsingMask( Model, Solver, OldMesh, TopMaskName, &
         .FALSE., OldTopPerm, dummyint)
  CALL MakePermUsingMask( Model, Solver, OldMesh, BotMaskName, &
         .FALSE., OldBotPerm, dummyint)

  !----------------------------------------------
  ! Check to see if we are solving the grounding line problem, if so we want to 
  ! grounded locations from bedrock variable rather than zs bottom to help with
  ! stability on the next time step
  !----------------------------------------------

  GLVarName = ListGetString(Params, "Grounding Line Variable Name", Found)
  IF(.NOT. Found) THEN
    CALL Info(SolverName, "No Grounding Line Variable Name found, assuming GroundedMask")
    GLVarName = "GroundedMask"
  END IF

  OldGLVar => VariableGet(OldMesh % Variables, GLVarName, .TRUE.)
  IF(ASSOCIATED(OldGLVar)) THEN
    DoGL = .TRUE.
  ELSE
    DoGL = .FALSE.
    IF(Found) THEN
      CALL Fatal(SolverName, "Specified Grounding Line Variable Name but variable not found!")
    ELSE
      CALL Info(SolverName, "Didn't find GroundedMask, not accounting for Grounding Line in remeshing.")
    END IF
  END IF

  !----------------------------------------------
  ! Get top and bottom coordinates from oldmesh for extrusion
  !----------------------------------------------

  !Get pointer to top and bottom vars in old mesh 
  TopVarName = "Zs Top"
  BotVarName = "Zs Bottom"

  OldTopVar => VariableGet(OldMesh % Variables, TopVarName, .TRUE.)
  IF(.NOT.ASSOCIATED(OldTopVar)) CALL Fatal(SolverName, "Couldn't get variable:&
         &RemeshTopSurf")
  OldBotVar => VariableGet(OldMesh % Variables, BotVarName, .TRUE.)
  IF(.NOT.ASSOCIATED(OldBotVar)) CALL Fatal(SolverName, "Couldn't get variable:&
        &RemeshBottomSurf")

  !When the model initialises, these two exported variables
  !share a perm with other vars, so we don't want to deallocate
  !However, once variables are copied to a new mesh, they have 
  !their own perm, and so we deallocate it here to avoid memory leak
  IF(FirstTime) THEN
    NULLIFY(OldBotVar % Perm, OldTopVar % Perm)
  ELSE
    DEALLOCATE(OldBotVar % Perm, OldTopVar % Perm)
  END IF

  n = OldMesh % NumberofNodes
  ALLOCATE(OldBotVarPerm(n), OldTopVarPerm(n))

  OldBotVar % Perm => OldBotVarPerm
  OldTopVar % Perm => OldTopVarPerm

  !mess with botperm before this point
  !and BotVar % values
  OldBotVar % Perm = OldBotPerm
  OldTopVar % Perm = OldTopPerm
  
  OldTopVar % Values = 0
  OldBotVar % Values = 0

  DO i=1,OldMesh % NumberOfNodes
    IF(OldTopVar % Perm(i) > 0) THEN
      OldTopVar % Values(OldTopVar % Perm(i)) = OldMesh % Nodes % z(i)
    ELSE
      OldTopVar % Values(OldTopVar % Perm(i)) = 0.0_dp
    END IF
    IF(OldBotVar % Perm(i) > 0) THEN
      OldBotVar % Values(OldBotVar % Perm(i)) = OldMesh % Nodes % z(i)
    END IF
  END DO

  ! Set up interp dimension
  n = ExtrudedMesh % NumberOfNodes
  ALLOCATE(InterpDim(1)); InterpDim(1) = 3

  !Allocate variables, set up permutation matrices, and add variables to ExtrudedMesh 
  n = ExtrudedMesh % NumberOfNodes
  ALLOCATE(TopVarValues(n),BotVarValues(n),TopVarPerm(n),BotVarPerm(n))
  TopVarPerm = 0; BotVarPerm = 0
  !TopVarValues = 0
  !BotVarValues = 0
  NodesPerLevel = n / ExtrudeLevels

  DO i=1,NodesPerLevel
    BotVarPerm(i) = i
    TopVarPerm(n - NodesPerLevel + i) = i
  END DO
  
  ! Add surface variable to extruded mesh
  CALL VariableAdd(ExtrudedMesh % Variables, ExtrudedMesh, Solver, TopVarName, 1, &
         TopVarValues, TopVarPerm, .TRUE.)

  ! Add bottom variable to extruded mesh
  CALL VariableAdd(ExtrudedMesh % Variables, ExtrudedMesh, Solver, BotVarName, 1, &
         BotVarValues, BotVarPerm, .TRUE.)
  
  ! If required, add Grounding Line variable to new mesh to be interpolated.
  ! We do this here, instead of in SwitchMesh, because nodes which will be
  ! grounded read their z coordinate from the specified bed, rather than the 
  ! old mesh, to avoid problems with GL on the next timestep
  IF(DoGL) THEN
    ALLOCATE(WorkPerm(ExtrudedMesh % NumberOfNodes), &
            WorkReal(COUNT(BotVarPerm > 0)))
    WorkPerm = BotVarPerm
    WorkReal = 0.0_dp
    CALL VariableAdd(ExtrudedMesh % Variables, ExtrudedMesh, Solver, GLVarName, 1, &
         WorkReal, WorkPerm, .TRUE.)
    NULLIFY(WorkReal, WorkPerm)
    NewGLVar => VariableGet(ExtrudedMesh % Variables, GLVarName, .TRUE.)
    IF(ASSOCIATED(OldGLVar % PrevValues)) THEN
      ALLOCATE(NewGLVar % PrevValues(SIZE(NewGLVar % Values), SIZE(OldGLVar % PrevValues,2)))
    END IF
  END IF  
  
  ! Run in parallel
  CALL ParallelActive(.TRUE.)

  ! Interpolate surface variable to mesh
  CALL InterpolateVarToVarReduced(OldMesh, ExtrudedMesh, TopVarName, InterpDim, UnfoundNodes,&
         GlobalEps=global_eps, LocalEps=local_eps) 
         
  IF(ANY(UnfoundNodes)) THEN
    DO i=1, SIZE(UnfoundNodes)
      IF(UnfoundNodes(i)) THEN
        PRINT *,ParEnv % MyPE,' Missing interped point: ', i, &
               ' x:', ExtrudedMesh % Nodes % x(i),&
               ' y:', ExtrudedMesh % Nodes % y(i),&
               ' z:', ExtrudedMesh % Nodes % z(i)
        CALL InterpolateUnfoundPoint( i, ExtrudedMesh, TopVarName, InterpDim )
      END IF
    END DO
    WRITE(Message,'(a,i0,a,i0,a)') "Failed to find ",COUNT(UnfoundNodes),' of ',&
           SIZE(UnfoundNodes),' nodes on top surface for mesh extrusion.'
    CALL Warn(SolverName, Message)
  END IF         

  IF(DoGL) THEN
    WorkVar => OldMesh % Variables
    IF(ASSOCIATED(WorkVar, OldGLVar)) THEN
      OldMesh % Variables => OldMesh % Variables % Next
      First = .TRUE.
    ELSE

      DO WHILE(ASSOCIATED(WorkVar))
        IF(ASSOCIATED(WorkVar % Next, OldGLVar)) EXIT
        WorkVar => WorkVar % Next
      END DO

      WorkVar % Next => OldGLVar % Next
      First = .FALSE.
    END IF
    NULLIFY(OldGLVar % Next)
  END IF

  ! Interpolate bottom variables to extrudedmesh
  CALL InterpolateVarToVarReduced(OldMesh, ExtrudedMesh, BotVarName, InterpDim, UnfoundNodes,&
         Variables=OldGLVar, GlobalEps=global_eps, LocalEps=local_eps)

  !Put GL var back in the linked list
  IF(DoGL) THEN
    IF(First) THEN
      OldGLVar % Next => OldMesh % Variables
      OldMesh % Variables => OldGLVar
    ELSE
      OldGLVar % Next => WorkVar % Next
      WorkVar % Next => OldGLVar
    END IF
  END IF

  IF(ANY(UnfoundNodes)) THEN
    DO i=1, SIZE(UnfoundNodes)
      IF(UnfoundNodes(i)) THEN
        PRINT *,ParEnv % MyPE,' Missing interped point: ', i, &
               ' x:', ExtrudedMesh % Nodes % x(i),&
               ' y:', ExtrudedMesh % Nodes % y(i),&
               ' z:', ExtrudedMesh % Nodes % z(i)
        CALL InterpolateUnfoundPoint( i, ExtrudedMesh, TopVarName, InterpDim )
      END IF
    END DO
    WRITE(Message,'(a,i0,a,i0,a)') "Failed to find ",COUNT(UnfoundNodes),' of ',&
           SIZE(UnfoundNodes),' nodes on bottom surface for mesh extrusion.'
    CALL Warn(SolverName, Message)
  END IF 

  ! Check that new surfaces were interpolated onto mesh
  NewTopVar => NULL(); NewBotVar => NULL()
  NewTopVar => VariableGet(ExtrudedMesh % Variables, TopVarName, .TRUE.)
  IF(.NOT. ASSOCIATED(NewTopVar)) CALL Fatal(SolverName, &
         "Couldn't find top surface variable on extruded mesh.")
  NewBotVar => VariableGet(ExtrudedMesh % Variables,BotVarName, .TRUE.)
  IF(.NOT. ASSOCIATED(NewBotVar)) CALL Fatal(SolverName, &
         "Couldn't find bottom surface variable on extruded mesh.")

!Grounded nodes should get coordinates from the bedrock function (i.e., Min Zs Bottom)
! TODO: generalize for different element types, if needed
  IF(DoGL) THEN
    NewGLVar => VariableGet(ExtrudedMesh % Variables, GLVarName, .TRUE.)
    IF(.NOT. ASSOCIATED(NewGLVar)) CALL Fatal(SolverName,&
      "Trying to account for the grounding line, but can't find GL var on new mesh.")

    IF (FirstTime) then
		  FirstTime=.False.

      ! open file
      OPEN(10,file='inputs/bedrock.xy')
      READ(10,*) nxbed
      READ(10,*) nybed
      ALLOCATE(xxbed(nxbed),yybed(nybed))
      ALLOCATE(dembed(nxbed,nybed))
      DO i=1,nxbed
    	  DO j=1,nybed
      	  READ(10,*) xxbed(i),yybed(j),dembed(i,j)
        END DO
		  END DO
		  CLOSE(10)
    END IF

    DO i=1,ExtrudedMesh % NumberOfNodes
      IF(NewGLVar % Perm(i) > 0) THEN
        IF(NewGLVar % Values(NewGLVar % Perm(i)) > -0.5) THEN
          x = ExtrudedMesh % Nodes % x (i)
          y = ExtrudedMesh % Nodes % y (i)
          !print *,'BED',x,y,NewBotVar % Values(NewBotVar % Perm(i)), LinearInterp(dembed,xxbed,yybed,nxbed,nybed,x,y)
          NewBotVar % Values(NewBotVar % Perm(i)) = LinearInterp(dembed,xxbed,yybed,nxbed,nybed,x,y)
        END IF 
      END IF
    END DO
  END IF

  !----------------------------------------------
  ! Map coordinates to extrudedmesh
  !----------------------------------------------

  DO i=1,ExtrudedMesh % NumberOfNodes
    IF(NewTopVar % Perm(i) > 0) THEN
      ExtrudedMesh % Nodes % z(i) = NewTopVar % Values(NewTopVar % Perm(i))
    ELSE IF(NewBotVar % Perm(i) > 0) THEN
      ExtrudedMesh % Nodes % z(i) = NewBotVar % Values(NewBotVar % Perm(i))
    ELSE
      ! Find index for top, bot i
      j = MOD(i,NodesPerLevel)
      IF (j == 0) THEN
        j = NodesPerLevel
      END IF

      bot = NewBotVar % Values(NewBotVar % Perm(j))
      top = NewTopVar % Values(NewTopVar % Perm(n-NodesPerLevel+j))
      ExtrudedMesh % Nodes % z(i) = ExtrudedMesh % Nodes % z(i) * (top-bot) + bot
    END IF
  END DO

  !PRINT *, ParEnv % MyPE, ' Debug, coordinate 1: ', MAXVAL(ExtrudedMesh % Nodes % x), MINVAL(ExtrudedMesh % Nodes % x)
  !PRINT *, ParEnv % MyPE, ' Debug, coordinate 2: ', MAXVAL(ExtrudedMesh % Nodes % y), MINVAL(ExtrudedMesh % Nodes % y)
  PRINT *, ParEnv % MyPE, ' Debug, coordinate 3: ', MAXVAL(ExtrudedMesh % Nodes % z), MINVAL(ExtrudedMesh % Nodes % z)

  !----------------------------------------------
  ! Deallocations 
  !----------------------------------------------

  !Delete unnecessary meshes
  CALL ReleaseMesh(FootprintMesh)
  DEALLOCATE(FootprintMesh)

  !----------------------------------------------
  ! Remove top, bottom variables from extrudedmesh so that we don't affect SwitchMesh
  !----------------------------------------------

  CALL ReleaseVariableList(ExtrudedMesh % Variables)
  NULLIFY(ExtrudedMesh % Variables)

  !----------------------------------------------
  ! Set new mesh as mapped mesh
  !----------------------------------------------

  NewMesh => ExtrudedMesh  

  NewMesh % Name = TRIM(OldMesh % Name)
  NewMesh % OutputActive = .TRUE.
  NewMesh % Changed = .TRUE. 

  !Ensure all partitions wait until all partitions have caught up
  IF(Parallel) CALL MPI_BARRIER(MPI_COMM_WORLD, ierr)

  CALL SwitchMesh(Model, Solver, OldMesh, NewMesh)
  CALL MeshStabParams( Model % Mesh )

  FirstTime = .FALSE.
  
  !----------------------------------------------
  ! Reset mesh update variables to 0 for next time step
  !----------------------------------------------

  DO i = 1,999
     WRITE(Message,'(A,I0)') 'Mesh Update Variable ',i
     VarName = ListGetString( Params, Message, Found)
     IF( .NOT. Found) EXIT

     Var => VariableGet( Model % Mesh % Variables, VarName, .TRUE. )
     IF(.NOT. ASSOCIATED(Var)) THEN
        WRITE(Message,'(A,A)') "Listed mesh update variable but cant find: ",VarName
        CALL Fatal(SolverName, Message)
     END IF
     Var % Values = 0.0_dp
  END DO

   ! TODO: check to see if this actually helps  
!  DO i = 1,999
!     WRITE(Message,'(A,I0)') 'Mesh Velocity Variable ',i
!     VarName = ListGetString( Params, Message, Found)
!     IF( .NOT. Found) EXIT
!
!     Var => VariableGet( Model % Mesh % Variables, VarName, .TRUE. )
!     IF(.NOT. ASSOCIATED(Var)) THEN
!        WRITE(Message,'(A,A)') "Listed mesh velocity variable but cant find: ",VarName
!        CALL Fatal(SolverName, Message)
!     END IF
!     Var % Values = 0.0_dp
!  END DO  

  !----------------------------------------------
  ! Deal with free surface variables for next time step
  !----------------------------------------------  

  !And set values equal to z coordinate
  DO k = 1,999
    WRITE(Message,'(A,I0)') 'FreeSurface Variable ',k
    VarName = ListGetString( Params, Message, Found)
    IF( .NOT. Found) EXIT

    Var => VariableGet( Model % Mesh % Variables, VarName, .TRUE. )
    IF(.NOT. ASSOCIATED(Var)) THEN
      WRITE(Message,'(A,A)') "Listed FreeSurface variable but cant find: ",VarName
      CALL Fatal(SolverName, Message)
    END IF

    RefVar => VariableGet( Model % Mesh % Variables, "Reference "//TRIM(VarName), .TRUE. )
    IF(.NOT. ASSOCIATED(RefVar)) THEN
      WRITE(Message,'(A,A)') "Listed FreeSurface variable but cant find: ",&
             "Reference "//TRIM(VarName)
      CALL Fatal(SolverName, Message)
    END IF

    DO i=1,Model % Mesh % NumberOfNodes
      IF(Var % Perm(i) <= 0) CYCLE
        Var % Values(Var % Perm(i)) = Model % Mesh % Nodes % z(i)
        RefVar % Values(RefVar % Perm(i)) = Model % Mesh % Nodes % z(i)
    END DO
     
  END DO


  !----------------------------------------------
  ! Get rid of unneccessary meshes and variables
  !----------------------------------------------
  
  !CALL ReleaseMesh(OldMesh)
  !DEALLOCATE(OldMesh)

CONTAINS

  SUBROUTINE SwitchMesh(Model, Solver, OldMesh, NewMesh)

    IMPLICIT NONE

    TYPE(Model_t) :: Model
    TYPE(Solver_t) :: Solver
    TYPE(Mesh_t), POINTER :: OldMesh, NewMesh
    !-------------------------------------------------
    TYPE(Solver_t), POINTER :: WorkSolver
    TYPE(Variable_t), POINTER :: Var=>NULL(), NewVar=>NULL(), WorkVar=>NULL()
    TYPE(Valuelist_t), POINTER :: Params
    TYPE(Matrix_t), POINTER :: WorkMatrix=>NULL()
    LOGICAL :: Found, Global, GlobalBubbles, Debug, DoPrevValues, &
         NoMatrix, DoOptimizeBandwidth, PrimaryVar, HasValuesInPartition, &
         PrimarySolver
    LOGICAL, POINTER :: UnfoundNodes(:)=>NULL()
    INTEGER :: i,j,k,DOFs, nrows,n
    INTEGER, POINTER :: WorkPerm(:)=>NULL()
    REAL(KIND=dp), POINTER :: WorkReal(:)=>NULL(), WorkReal2(:)=>NULL(), PArray(:,:) => NULL()
    REAL(KIND=dp) :: FrontOrientation(3), RotationMatrix(3,3), UnRotationMatrix(3,3), &
         globaleps, localeps
    CHARACTER(LEN=MAX_NAME_LEN) :: SolverName, WorkName

    INTERFACE
       SUBROUTINE InterpolateMeshToMesh2( OldMesh, NewMesh, OldVariables, &
            NewVariables, UseQuadrantTree, Projector, MaskName, UnfoundNodes )
         !------------------------------------------------------------------------------
         USE Lists
         USE SParIterComm
         USE Interpolation
         USE CoordinateSystems
         !-------------------------------------------------------------------------------
         TYPE(Mesh_t), TARGET  :: OldMesh, NewMesh
         TYPE(Variable_t), POINTER, OPTIONAL :: OldVariables, NewVariables
         LOGICAL, OPTIONAL :: UseQuadrantTree
         LOGICAL, POINTER, OPTIONAL :: UnfoundNodes(:)
         TYPE(Projector_t), POINTER, OPTIONAL :: Projector
         CHARACTER(LEN=*),OPTIONAL :: MaskName
       END SUBROUTINE InterpolateMeshToMesh2
    END INTERFACE

    SolverName = "SwitchMesh"
    Debug = .FALSE.
    Params => Solver % Values
    CALL Info( 'Remesher', ' ',Level=4 )
    CALL Info( 'Remesher', '-------------------------------------',Level=4 )
    CALL Info( 'Remesher', ' Switching from old to new mesh...',Level=4 )
    CALL Info( 'Remesher', '-------------------------------------',Level=4 )
    CALL Info( 'Remesher', ' ',Level=4 )

    !interpolation epsilons
    globaleps = global_eps
    localeps = local_eps


    IF(ASSOCIATED(NewMesh % Variables)) CALL Fatal(SolverName,&
         "New mesh already has variables associated!")    

    CALL CopyIntrinsicVars(OldMesh, NewMesh)

    !----------------------------------------------
    ! Add Variables to NewMesh
    !----------------------------------------------

    Var => OldMesh % Variables
    DO WHILE( ASSOCIATED(Var) )

      DoPrevValues = ASSOCIATED(Var % PrevValues)
      WorkSolver => Var % Solver
      HasValuesInPartition = .TRUE.

      !Do nothing if it already exists
      NewVar => VariableGet( NewMesh % Variables, Var % Name, ThisOnly = .TRUE.)
      IF(ASSOCIATED(NewVar)) THEN
        NULLIFY(NewVar)
        Var => Var % Next
        CYCLE
      END IF

      DOFs = Var % DOFs
      Global = (SIZE(Var % Values) .EQ. DOFs)

      !Allocate storage for values and perm
      IF(Global) THEN 
      
        ALLOCATE(WorkReal(DOFs))
        WorkReal = Var % Values
        
        CALL VariableAdd( NewMesh % Variables, NewMesh, &
              Var % Solver, TRIM(Var % Name), &
              Var % DOFs, WorkReal)

      ELSE !Regular field variable

        ALLOCATE(WorkPerm(NewMesh % NumberOfNodes))

        IF(ASSOCIATED(WorkSolver)) THEN

          WRITE(Message, '(A,A)' ) "Allocating field variable ", Var % Name
          CALL Info(SolverName, Message)

          PrimaryVar = ASSOCIATED(WorkSolver % Variable, Var)

          IF(PrimaryVar) THEN !Take care of the matrix
             NoMatrix = ListGetLogical( WorkSolver % Values, 'No matrix',Found)
             !Issue here, this will recreate matrix for every variable associated w/ solver.

             IF(.NOT. NoMatrix) THEN
                IF(ParEnv % MyPE == 0) PRINT *, 'Computing matrix for variable: ',TRIM(Var % Name)

                DoOptimizeBandwidth = ListGetLogical( WorkSolver % Values, &
                     'Optimize Bandwidth', Found )
                IF ( .NOT. Found ) DoOptimizeBandwidth = .TRUE.

                GlobalBubbles = ListGetLogical( WorkSolver % Values, &
                     'Bubbles in Global System', Found )
                IF ( .NOT. Found ) GlobalBubbles = .TRUE.

                WorkMatrix => CreateMatrix(Model, WorkSolver, &
                     NewMesh, WorkPerm, DOFs, MATRIX_CRS, DoOptimizeBandwidth, &
                     ListGetString( WorkSolver % Values, 'Equation' ), &
                     GlobalBubbles = GlobalBubbles )

                IF(ASSOCIATED(WorkMatrix)) THEN
                   WorkMatrix % Comm = MPI_COMM_WORLD

                   WorkMatrix % Symmetric = ListGetLogical( WorkSolver % Values, &
                        'Linear System Symmetric', Found )

                   WorkMatrix % Lumped = ListGetLogical( WorkSolver % Values, &
                        'Lumped Mass Matrix', Found )

                   CALL AllocateVector( WorkMatrix % RHS, WorkMatrix % NumberOfRows )
                   WorkMatrix % RHS = 0.0_dp
                   WorkMatrix % RHS_im => NULL()

                   ALLOCATE(WorkMatrix % Force(WorkMatrix % NumberOfRows, WorkSolver % TimeOrder+1))
                   WorkMatrix % Force = 0.0_dp
                ELSE
                   !No nodes in this partition now
                   NoMatrix = .TRUE.
                END IF
             END IF

             IF ( ASSOCIATED(Var % EigenValues) ) THEN
                n = SIZE(Var % EigenValues)

                IF ( n > 0 ) THEN
                   WorkSolver % NOFEigenValues = n
                   CALL AllocateVector( NewVar % EigenValues,n )
                   CALL AllocateArray( NewVar % EigenVectors, n, &
                        SIZE(NewVar % Values) ) 

                   NewVar % EigenValues  = 0.0d0
                   NewVar % EigenVectors = 0.0d0
                   IF(.NOT.NoMatrix) THEN
                      CALL AllocateVector( WorkMatrix % MassValues, SIZE(WorkMatrix % Values) )
                      WorkMatrix % MassValues = 0.0d0
                   END IF
                END IF
             END IF

             IF(ASSOCIATED(WorkSolver % Matrix)) CALL FreeMatrix(WorkSolver % Matrix)
             WorkSolver % Matrix => WorkMatrix

             !Check for duplicate solvers with same var
             DO j=1,Model % NumberOfSolvers
                IF(ASSOCIATED(WorkSolver, Model % Solvers(j))) CYCLE
                IF(.NOT. ASSOCIATED(Model % Solvers(j) % Variable)) CYCLE
                IF( TRIM(Model % Solvers(j) % Variable % Name) /= TRIM(Var % Name)) CYCLE
                !Ideally, the solver's old matrix would be freed here, but apart from the 
                !first timestep, it'll be a duplicate
                IF(ASSOCIATED(Model % Solvers(j) % Matrix, WorkMatrix)) CYCLE
                !CALL FreeMatrix(Model % Solvers(j) % Matrix)
                print *,'Solver is ', Model % Solvers(j) % Variable % Name
                !Model % Solvers(j) % Matrix => WorkMatrix
             END DO

             NULLIFY(WorkMatrix)

             !NOTE: We don't switch Solver % Variable here, because
             !Var % Solver % Var doesn't necessarily point to self
             !if solver has more than one variable. We do this below.
          ELSE
             k = InitialPermutation(WorkPerm, Model, WorkSolver, &
                  NewMesh, ListGetString(WorkSolver % Values,'Equation'))
          END IF !Primary var

          HasValuesInPartition = COUNT(WorkPerm>0) > 0
          IF(HasValuesInPartition) THEN
             ALLOCATE(WorkReal(COUNT(WorkPerm>0)*DOFs))
          ELSE
             !this is silly but it matches AddEquationBasics
             ALLOCATE(WorkReal(NewMesh % NumberOfNodes * DOFs))
          END IF

          WorkReal = 0.0_dp
          CALL VariableAdd( NewMesh % Variables, NewMesh, &
               Var % Solver, TRIM(Var % Name), &
               Var % DOFs, WorkReal, WorkPerm, &
               Var % Output, Var % Secondary, Var % TYPE )
        
          NewVar => VariableGet( NewMesh % Variables, Var % Name, ThisOnly = .TRUE. )
          IF(.NOT.ASSOCIATED(NewVar)) CALL Fatal(SolverName,&
                "Problem creating variable on new mesh.")
    
          IF(DoPrevValues) THEN 
            ALLOCATE(NewVar % PrevValues( SIZE(NewVar % Values), SIZE(Var % PrevValues,2) ))
          END IF

          !Add the components of variables with more than one DOF
          !NOTE, this implementation assumes the vector variable
          !comes before the scalar components in the list.
          !e.g., we add Mesh Update and so here we add MU 1,2,3
          !SO: next time round, new variable (MU 1) already exists
          !and so it's CYCLE'd
          IF((DOFs > 1) .AND. (.NOT.Global)) THEN
            nrows = SIZE(WorkReal)
            DO i=1,DOFs
             
              WorkReal2 => WorkReal( i:nrows-DOFs+i:DOFs )
              WorkName = ComponentName(TRIM(Var % Name),i)
              CALL VariableAdd( NewMesh % Variables, NewMesh, &
                   Var % Solver, WorkName, &
                   1, WorkReal2, WorkPerm, &
                   Var % Output, Var % Secondary, Var % TYPE )

              IF(DoPrevValues) THEN
                WorkVar => VariableGet( NewMesh % Variables, WorkName, .TRUE. )
                IF(.NOT. ASSOCIATED(WorkVar)) CALL Fatal(SolverName, &
                    "Error allocating Remesh Update PrevValues.")

                NULLIFY(WorkVar % PrevValues)
                WorkVar % PrevValues => NewVar % PrevValues(i:nrows-DOFs+i:DOFs,:)
              END IF
  
              NULLIFY(WorkReal2)
            END DO
          END IF
       
        END IF !(ASSOCIATED(WorkSolver))
      END IF !Not global     

      NULLIFY(WorkReal, WorkPerm)
      Var => Var % Next
    END DO
    
    !set partitions to active, so variable can be -global -nooutput
    CALL ParallelActive(.TRUE.) 
!    !MPI_BSend buffer issue in this call to InterpolateMeshToMesh
    CALL InterpolateMeshToMesh2( OldMesh, NewMesh, OldMesh % Variables, UnfoundNodes=UnfoundNodes)
    IF(ANY(UnfoundNodes)) THEN
       PRINT *, ParEnv % MyPE, ' missing ', COUNT(UnfoundNodes),' out of ',SIZE(UnfoundNodes),&
            ' nodes in SwitchMesh.'
    END IF
    
    !---------------------------------------------------------
    ! For top, bottom and calving front BC, do reduced dim 
    ! interpolation to avoid epsilon problems
    !---------------------------------------------------------

    CALL InterpMaskedBCReduced(Model, Solver, OldMesh, NewMesh, OldMesh % Variables, &
         "Top Surface Mask",globaleps=globaleps,localeps=localeps)
    CALL InterpMaskedBCReduced(Model, Solver, OldMesh, NewMesh, OldMesh % Variables, &
         "Bottom Surface Mask",globaleps=globaleps,localeps=localeps)
    
    !-----------------------------------------------
    ! Point solvers at the correct mesh and variable
    !-----------------------------------------------
    DO i=1,Model % NumberOfSolvers
       WorkSolver => Model % Solvers(i)

       WorkSolver % Mesh => NewMesh !note, assumption here that there's only one active mesh

       !hack to get SingleSolver to recompute
       !should be taken care of by Mesh % Changed, but
       !this is reset by CoupledSolver for some reason
       WorkSolver % NumberOfActiveElements = -1 

       IF(.NOT. ASSOCIATED(WorkSolver % Variable)) CYCLE
       IF(WorkSolver % Variable % NameLen == 0) CYCLE !dummy  !invalid read

       !Check for multiple solvers with same var:
       !If one of the duplicate solvers is only executed before the simulation (or never),
       !then we don't point the variable at this solver. (e.g. initial groundedmask).
       !If both solvers are executed during each timestep, we have a problem.
       !If neither are, it doesn't matter, and so the the later occurring solver will have
       !the variable pointed at it (arbitrary).
       PrimarySolver = .TRUE.
       DO j=1,Model % NumberOfSolvers
          IF(j==i) CYCLE
          IF(.NOT. ASSOCIATED(Model % Solvers(j) % Variable)) CYCLE
          IF(TRIM(Model % Solvers(j) % Variable % Name) == WorkSolver % Variable % Name) THEN

             IF( (WorkSolver % SolverExecWhen == SOLVER_EXEC_NEVER) .OR. &
                  (WorkSolver % SolverExecWhen == SOLVER_EXEC_AHEAD_ALL) ) THEN
                IF((Model % Solvers(j) % SolverExecWhen == SOLVER_EXEC_NEVER) .OR. &
                     (Model % Solvers(j) % SolverExecWhen == SOLVER_EXEC_AHEAD_ALL) ) THEN
                   PrimarySolver = .TRUE.
                ELSE
                   PrimarySolver = .FALSE.
                   WorkSolver % Matrix => NULL()
                   EXIT
                END IF
             ELSE
                IF( (Model % Solvers(j) % SolverExecWhen == SOLVER_EXEC_NEVER) .OR. &
                     (Model % Solvers(j) % SolverExecWhen == SOLVER_EXEC_AHEAD_ALL) ) THEN
                   PrimarySolver = .TRUE.
                   EXIT
                ELSE
                   WRITE(Message, '(A,A)') "Unable to determine main solver for variable: ", &
                        TRIM(WorkSolver % Variable % Name)
                   CALL Fatal(SolverName, Message)
                END IF
             END IF

          END IF
       END DO

       WorkVar => VariableGet(NewMesh % Variables, &
            WorkSolver % Variable % Name, .TRUE.) !invalid read

       IF(ASSOCIATED(WorkVar)) THEN
          WorkSolver % Variable => WorkVar
          IF(PrimarySolver) WorkVar % Solver => WorkSolver
       ELSE
          WRITE(Message, '(a,a,a)') "Variable ",WorkSolver % Variable % Name," wasn't &
               &correctly switched to the new mesh." !invalid read
          PRINT *, i,' debug, solver equation: ', ListGetString(WorkSolver % Values, "Equation")
          CALL Fatal(SolverName, Message)
       END IF

    END DO

    NewMesh % Next => OldMesh % Next
    Model % Meshes => NewMesh
    Model % Mesh => NewMesh
    Model % Variables => NewMesh % Variables

    !Free old mesh and associated variables
    CALL ReleaseMesh(OldMesh)
    DEALLOCATE(OldMesh)
!    DEALLOCATE(UnfoundNodes)

    OldMesh => Model % Meshes

  END SUBROUTINE SwitchMesh
!
!  !Taken from TwoMeshes
!  !------------------------------------------------------------------------------
!  SUBROUTINE SetDirichtletPoint( StiffMatrix, ForceVector,DOF, NDOFs, &
!       Perm, NodeIndex, NodeValue) 
!    !------------------------------------------------------------------------------
!
!    IMPLICIT NONE
!
!    TYPE(Matrix_t), POINTER :: StiffMatrix
!    REAL(KIND=dp) :: ForceVector(:), NodeValue
!    INTEGER :: DOF, NDOFs, Perm(:), NodeIndex
!    !------------------------------------------------------------------------------
!
!    INTEGER :: PermIndex
!    REAL(KIND=dp) :: s
!
!    !------------------------------------------------------------------------------
!
!    PermIndex = Perm(NodeIndex)
!
!    IF ( PermIndex > 0 ) THEN
!       PermIndex = NDOFs * (PermIndex-1) + DOF
!
!       IF ( StiffMatrix % FORMAT == MATRIX_SBAND ) THEN        
!          CALL SBand_SetDirichlet( StiffMatrix,ForceVector,PermIndex,NodeValue )        
!       ELSE IF ( StiffMatrix % FORMAT == MATRIX_CRS .AND. &
!            StiffMatrix % Symmetric ) THEN        
!          CALL CRS_SetSymmDirichlet(StiffMatrix,ForceVector,PermIndex,NodeValue)        
!       ELSE                          
!          s = StiffMatrix % Values(StiffMatrix % Diag(PermIndex))
!          ForceVector(PermIndex) = NodeValue * s
!          CALL ZeroRow( StiffMatrix,PermIndex )
!          CALL SetMatrixElement( StiffMatrix,PermIndex,PermIndex,1.0d0*s )        
!       END IF
!    END IF
!
!    !------------------------------------------------------------------------------
!  END SUBROUTINE SetDirichtletPoint
  !------------------------------------------------------------------------------

  !Constructs the local matrix for the "d2U/dz2 = 0" Equation
  !------------------------------------------------------------------------------
  SUBROUTINE LocalMatrix(  STIFF, FORCE, Element, n )
    !------------------------------------------------------------------------------
    REAL(KIND=dp) :: STIFF(:,:), FORCE(:)
    INTEGER :: n
    TYPE(Element_t), POINTER :: Element
    !------------------------------------------------------------------------------
    REAL(KIND=dp) :: Basis(n),dBasisdx(n,3),DetJ
    LOGICAL :: Stat
    INTEGER :: t, p, q, dim
    TYPE(GaussIntegrationPoints_t) :: IP

    TYPE(Nodes_t) :: Nodes
    SAVE Nodes
    !------------------------------------------------------------------------------
    CALL GetElementNodes( Nodes, Element)

    FORCE = 0.0_dp
    STIFF = 0.0_dp

    dim = CoordinateSystemDimension()

    !Numerical integration:
    !----------------------
    IP = GaussPoints( Element )
    DO t=1,IP % n
       stat = ElementInfo( Element, Nodes, IP % U(t), IP % V(t), &
            IP % W(t),  detJ, Basis, dBasisdx )

       DO p=1,n
          DO q=1,n
             STIFF(p,q) = STIFF(p,q) + IP % S(t) * detJ * dBasisdx(q,dim)*dBasisdx(p,dim)
          END DO
       END DO
    END DO
    !------------------------------------------------------------------------------
  END SUBROUTINE LocalMatrix

  SUBROUTINE InterpMaskedBCReduced(Model, Solver, OldMesh, NewMesh, Variables, MaskName, &
       SeekNodes, globaleps, localeps)

    USE InterpVarToVar

    IMPLICIT NONE

    TYPE(Model_t) :: Model
    TYPE(Solver_t) :: Solver
    TYPE(Mesh_t), POINTER :: OldMesh, NewMesh
    TYPE(Variable_t), POINTER :: Variables
    INTEGER, POINTER :: OldMaskPerm(:)=>NULL(), NewMaskPerm(:)=>NULL()
    INTEGER, POINTER  :: InterpDim(:)
    INTEGER :: dummyint
    REAL(KIND=dp), OPTIONAL :: globaleps,localeps
    REAL(KIND=dp) :: geps,leps
    LOGICAL, POINTER :: OldMaskLogical(:), NewMaskLogical(:), UnfoundNodes(:)=>NULL()
    LOGICAL, POINTER, OPTIONAL :: SeekNodes(:)
    CHARACTER(LEN=*) :: MaskName

    CALL MakePermUsingMask( Model, Solver, NewMesh, MaskName, &
         .FALSE., NewMaskPerm, dummyint)

    CALL MakePermUsingMask( Model, Solver, OldMesh, MaskName, &
         .FALSE., OldMaskPerm, dummyint)

    ALLOCATE(OldMaskLogical(SIZE(OldMaskPerm)),&
         NewMaskLogical(SIZE(NewMaskPerm)))

    OldMaskLogical = (OldMaskPerm <= 0)
    NewMaskLogical = (NewMaskPerm <= 0)
    IF(PRESENT(SeekNodes)) NewMaskLogical = &
         NewMaskLogical .OR. .NOT. SeekNodes

    IF(PRESENT(globaleps)) THEN
      geps = globaleps
    ELSE
      geps = 1.0E-4
    END IF

    IF(PRESENT(localeps)) THEN
      leps = localeps
    ELSE
      leps = 1.0E-4
    END IF

    IF(Debug) PRINT *, ParEnv % MyPE,'Debug, on boundary: ',TRIM(MaskName),' seeking ',&
         COUNT(.NOT. NewMaskLogical),' of ',SIZE(NewMaskLogical),' nodes.'

    ALLOCATE(InterpDim(1))
    InterpDim(1) = 3

    CALL ParallelActive(.TRUE.)
    CALL InterpolateVarToVarReduced(OldMesh, NewMesh, "mesh update 3", InterpDim, &
         UnfoundNodes, OldMaskLogical, NewMaskLogical, Variables=OldMesh % Variables, &
         GlobalEps=geps, LocalEps=leps)

    IF(ANY(UnfoundNodes)) THEN
      !NewMaskLogical changes purpose, now it masks supporting nodes
      NewMaskLogical = (NewMaskPerm <= 0)

      DO i=1, SIZE(UnfoundNodes)
          IF(UnfoundNodes(i)) THEN
             PRINT *,ParEnv % MyPE,'Didnt find point: ', i, &
                  ' x:', NewMesh % Nodes % x(i),&
                  ' y:', NewMesh % Nodes % y(i),&
                  ' z:', NewMesh % Nodes % z(i)
             CALL InterpolateUnfoundPoint( i, NewMesh, "mesh update 3", InterpDim, &
                  NodeMask=NewMaskLogical, Variables=NewMesh % Variables )
          END IF
       END DO

       WRITE(Message, '(i0,a,a,a,i0,a,i0,a)') ParEnv % MyPE,&
            ' Failed to find all points on face: ',MaskName, ', ',&
            COUNT(UnfoundNodes),' of ',COUNT(.NOT. NewMaskLogical),' missing points.'
       CALL Warn("InterpMaskedBCReduced", Message)
    END IF

    DEALLOCATE(OldMaskLogical, &
         NewMaskLogical, NewMaskPerm, &
         OldMaskPerm, UnfoundNodes)

  END SUBROUTINE InterpMaskedBCReduced
  
END SUBROUTINE ReMesh

!------------------------------------------------------------------!
include 'Interp.f90' !
!------------------------------------------------------------------!