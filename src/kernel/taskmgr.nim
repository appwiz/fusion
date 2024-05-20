#[
  Task management
]#

import common/pagetables
import cpu
import loader
import gdt
import sched
import taskdef
import vmm


{.experimental: "codeReordering".}

var
  tasks = newSeq[Task]()
  nextTaskId: uint64 = 0

proc iretq*() {.asmNoStackFrame.} =
  ## We push the address of this proc after the interrupt stack frame so that a simple
  ## `ret` instruction will execute this proc, which then returns to the new task. This
  ## makes returning from both new and interrupted tasks the same.
  asm "iretq"

proc createStack*(
  vmRegions: var seq[VMRegion],
  pml4: ptr PML4Table,
  space: var VMAddressSpace,
  npages: uint64,
  mode: PageMode
): TaskStack =
  let stackRegion = vmalloc(space, npages)
  vmmap(stackRegion, pml4, paReadWrite, mode, noExec = true)
  vmRegions.add(stackRegion)
  result.data = cast[ptr UncheckedArray[uint64]](stackRegion.start)
  result.size = npages * PageSize
  result.bottom = cast[uint64](result.data) + result.size

# task initial stack frame
#
# stack
# bottom --> +-------------------+
#            | ss                |
#            | rsp               |
#            | rflags            | <-- `InterruptStackFrame` (pushed/popped by cpu)
#            | cs                |
#            | rip               |
#            +-------------------+
#            | iretq proc ptr    | <-- `ret` instruction will pop this into `rip`, which
#            +-------------------+     will execute `iretq`
#            | rax               |
#            | ...               |
#            | ...               | <-- `TaskRegs` (pushed/popped by kernel)
#            | ...               |
#    rsp --> | r15               |
#            +-------------------+
#

proc createUserTask*(
  imagePhysAddr: PhysAddr,
  imagePageCount: uint64,
  name: string = "",
  priority: TaskPriority = 0
): Task =

  var vmRegions = newSeq[VMRegion]()
  var pml4 = cast[ptr PML4Table](new PML4Table)

  debugln &"tasks: Loading task from ELF image"
  let imagePtr = cast[pointer](p2v(imagePhysAddr))
  let loadedImage = load(imagePtr, pml4)
  vmRegions.add(loadedImage.vmRegion)
  debugln &"tasks: Loaded task at: {loadedImage.vmRegion.start.uint64:#x}"

  # map kernel space
  # debugln &"tasks: Mapping kernel space in task's page table"
  var kpml4 = getActivePML4()
  for i in 256 ..< 512:
    pml4.entries[i] = kpml4.entries[i]

  # create user and kernel stacks
  # debugln &"tasks: Creating task stacks"
  let ustack = createStack(vmRegions, pml4, uspace, 1, pmUser)
  let kstack = createStack(vmRegions, pml4, kspace, 1, pmSupervisor)

  # create stack frame

  # debugln &"tasks: Setting up interrupt stack frame"
  let isfAddr = kstack.bottom - sizeof(InterruptStackFrame).uint64
  var isf = cast[ptr InterruptStackFrame](isfAddr)
  isf.ss = cast[uint64](DataSegmentSelector)
  isf.rsp = cast[uint64](ustack.bottom)
  isf.rflags = cast[uint64](0x202)
  isf.cs = cast[uint64](UserCodeSegmentSelector)
  isf.rip = cast[uint64](loadedImage.entryPoint)

  # debugln &"tasks: Setting up iretq proc ptr"
  let iretqPtrAddr = isfAddr - sizeof(uint64).uint64
  var iretqPtr = cast[ptr uint64](iretqPtrAddr)
  iretqPtr[] = cast[uint64](iretq)

  # debugln &"tasks: Setting up task registers"
  let regsAddr = iretqPtrAddr - sizeof(TaskRegs).uint64
  var regs = cast[ptr TaskRegs](regsAddr)
  zeroMem(regs, sizeof(TaskRegs))
  regs.rdi = 5050

  let taskId = nextTaskId
  inc nextTaskId

  result = Task(
    id: taskId,
    name: name,
    priority: priority,
    vmRegions: vmRegions,
    pml4: pml4,
    ustack: ustack,
    kstack: kstack,
    rsp: regsAddr,
    state: TaskState.New,
    isUser: true,
  )

  tasks.add(result)

  debugln &"tasks: Created user task {taskId}"

type
  KernelProc* = proc () {.cdecl.}

proc kernelTaskWrapper*(kproc: KernelProc) =
  debugln &"tasks: Running kernel task \"{getCurrentTask().name}\""
  kproc()
  terminate()

proc createKernelTask*(kproc: KernelProc, name: string = "", priority: TaskPriority = 0): Task =

  var vmRegions = newSeq[VMRegion]()
  var pml4 = getActivePML4()

  debugln &"tasks: Creating kernel task"
  let kstack = createStack(vmRegions, pml4, kspace, 1, pmSupervisor)

  # create stack frame

  # debugln &"tasks: Setting up interrupt stack frame"
  let isfAddr = kstack.bottom - sizeof(InterruptStackFrame).uint64
  var isf = cast[ptr InterruptStackFrame](isfAddr)
  isf.ss = 0  # kernel ss selector must be null
  isf.rsp = cast[uint64](kstack.bottom)
  isf.rflags = cast[uint64](0x202)
  isf.cs = cast[uint64](KernelCodeSegmentSelector)
  isf.rip = cast[uint64](kernelTaskWrapper)

  # debugln &"tasks: Setting up iretq proc ptr"
  let iretqPtrAddr = isfAddr - sizeof(uint64).uint64
  var iretqPtr = cast[ptr uint64](iretqPtrAddr)
  iretqPtr[] = cast[uint64](iretq)

  # debugln &"tasks: Setting up task registers"
  let regsAddr = iretqPtrAddr - sizeof(TaskRegs).uint64
  var regs = cast[ptr TaskRegs](regsAddr)
  zeroMem(regs, sizeof(TaskRegs))
  regs.rdi = cast[uint64](kproc)  # pass kproc as an argument to kernelTaskWrapper

  let taskId = nextTaskId
  inc nextTaskId

  result = Task(
    id: taskId,
    name: name,
    priority: priority,
    vmRegions: vmRegions,
    pml4: pml4,
    kstack: kstack,
    rsp: regsAddr,
    state: TaskState.New,
    isUser: false,
  )
  tasks.add(result)

  debugln &"tasks: Created kernel task {taskId}"

###
# Task operations on self
###

proc suspend*() =
  var task = sched.getCurrentTask()
  debugln &"tasks: Suspending task {task.id}"
  task.state = TaskState.Suspended
  sched.removeTask(task)
  sched.schedule()
  debugln &"tasks: Resumed task {task.id}"

proc terminate*() =
  var task = sched.getCurrentTask()
  debugln &"tasks: Terminating task {task.id}"
  task.state = TaskState.Terminated
  # vmfree(task.space, task.ustack.data, task.ustack.size div PageSize)
  # vmfree(task.space, task.kstack.data, task.kstack.size div PageSize)
  sched.removeTask(task)
  sched.schedule()

###
# Task operations on other tasks
###

proc resume*(task: Task) =
  debugln &"tasks: Resuming task {task.id}"
  task.state = TaskState.Ready
  sched.addTask(task)
