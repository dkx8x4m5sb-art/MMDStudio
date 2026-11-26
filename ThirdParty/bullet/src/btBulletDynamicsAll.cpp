// Bullet dynamics, trimmed to what a rigid-body chain needs.
//
// The stock btBulletDynamicsAll.cpp also pulls in Featherstone multibodies,
// the raycast vehicle, the kinematic character controller and the MLCP
// solvers. None of that is reachable from PMX data, and each one costs
// compile time and a few hundred KB of object code, so they are left out.

#include "BulletDynamics/Dynamics/btDiscreteDynamicsWorld.cpp"
#include "BulletDynamics/Dynamics/btRigidBody.cpp"
#include "BulletDynamics/Dynamics/btSimpleDynamicsWorld.cpp"

#include "BulletDynamics/ConstraintSolver/btConeTwistConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btGeneric6DofSpringConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btSliderConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btContactConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btHinge2Constraint.cpp"
#include "BulletDynamics/ConstraintSolver/btSolve2LinearConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btFixedConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btHingeConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btTypedConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btGearConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btNNCGConstraintSolver.cpp"
#include "BulletDynamics/ConstraintSolver/btUniversalConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btGeneric6DofConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btPoint2PointConstraint.cpp"
#include "BulletDynamics/ConstraintSolver/btGeneric6DofSpring2Constraint.cpp"
#include "BulletDynamics/ConstraintSolver/btSequentialImpulseConstraintSolver.cpp"
