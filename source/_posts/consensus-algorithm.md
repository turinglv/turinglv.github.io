---
title: 分布式一致性算法介绍
date: 2020-01-05
categories:
    - Distributed
    - Zookeeper
    - paxos
    - ZAB
    - Raft
tags:
    - Zookeeper
    - paxos
    - ZAB
    - Raft
typora-root-url: ../../source
---

## 分布式共识算法

### 分布式共识（Consensus）

多个参与者针对某一件事达成完全一致：一件事，一个结论。已达成一致的结论，不可推翻。

为了达成一致，每个进程都提出自己的提议（propose），最终通过分布式一致性算法，所有正确运行的进程决定（decide）相同的值。

如果在一个不出现故障的系统中，很容易解决分布式一致性问题。但是实际分布式系统一般是基于消息传递的异步分布式系统，进程可能会慢、被杀死或者重启，消息可能会延迟、丢失、重复、乱序等。

在一个可能发生上述异常的分布式系统中如何就某个值达成一致，形成一致的决议，保证不论发生以上任何异常，都不会破坏决议的一致性，这些正是一致性算法要解决的问题。

### FLP Impossibility 理论

FLP定理是分布式理论中最重要的理论之一，它指出**在最小化异步网络通信场景下，即使只有一个节点失败，也没有一种确定性的共识算法能够使得在其他节点之间保持数据一致。**不可能定理是基于异步系统模型而做的证明，这是一个非常受限的模型，它假定共识算法不能使用任何时钟或超时机制来检测崩溃节点，并且消息仅会被传送一次。

一个**正确**的分布式算法需要满足两条性质：

- Safety：具备Safety性质的算法保证坏的事情绝对不会发生，例如对于满足Safety性质的分布式选主(Leader election)算法，绝对不会出现一个以上进程被选为Leader的情况。
- Liveness：具备Liveness性质的算法保证好的事情终将发生，即算法在有限的时间内可以结束

综上，一个**正确**的分布式算法可以在**指定的分布式系统模型**中保证**Safety**和**Liveness**属性

而FLP不可能原理则是在说，异步网络中liveness和safety是一对冤家. total correct意味着要同时满足safety和liveness，但只要有一个faulty process这就是不可能的

分布式系统的共识有以下三个标准，并且缺一不可：

- Termination（终止性）非失败进程最终需要决定一个值
- Agreement（一致性）所有的进程必须决定的值必须是同一个值
- Validity（有效性）这个被决定的值必须是被某些进程提出的

我们所知的一致性算法如 Paxos 或 Raft 都不是真正意义上的一致性算法，因为它们无法同时满足上面的三个条件

### CAP 理论

CAP理论是分布式系统（特别是分布式存储领域中被讨论的最多的理论）

- C代表一致性 (Consistency)
  - 一个写操作返回成功，那么之后的读请求都必须读到这个新数据；
  - 如果返回失败，那么所有读操作都不能读到这个数据。所有节点访问同一份最新的数据
- A代表可用性 (Availability)
  - 对数据更新具备高可用性，请求能够及时处理，不会一直等待，即使出现节点失效
- P代表分区容错性 (Partition tolerance)
  - 能容忍网络分区，在网络断开的情况下，被分隔的节点仍能正常对外提供服务

CAP理论告诉我们C、A、P三者不能同时满足，最多只能满足其中两个

![See the source image](/images/consensus-algorithm/OIP-C.vQ1Wb2s91lSwkgNfTBfeFgHaGa)

理解CAP理论最简单的方式是想象两个副本处于分区两侧，即两个副本之间的网络断开，不能通信

- 如果允许其中一个副本更新，则会导致数据不一致，即丧失了C性质。
- 如果为了保证一致性，将分区某一侧的副本设置为不可用，那么又丧失了A性质。
- 除非两个副本可以互相通信，才能既保证C又保证A，这又会导致丧失P性质。

一般来说使用网络通信的分布式系统，无法舍弃P性质，那么就只能在一致性和可用性上做一个艰难的选择，Paxos、Raft等分布式一致性算法就是在一致性和可用性之间做到了很好的平衡的见证

### BASE 理论

BASE 理论是 eBay 架构师对大规模互联网分布式系统实践的总结，并在 ACM 上发表了 **[Base: An Acid Alternative](https://queue.acm.org/detail.cfm?id=1394128)** 一文，其核心思想是**即使无法做到强一致性，但每个应用都可以根据自身业务特点，采用适当的方式来使系统达到最终一致性**。

BASE 是对 CAP 中一致性和可用性权衡的结果，对分布式系统提出了三个概念：

- 基本可用（Basically Available）
- 软（弱）状态（Soft State）
- 最终一致性（Eventually Consistent）

BASE 理论表明要实现系统的横向扩展，就要对业务进行功能分区，将数据的不同功能组迁移到相互独立的数据库服务器上。由于降低了事务的耦合度，就不能单纯依赖数据库的约束来保证功能组之间的一致性，BASE 提出使用消息队列来异步执行解耦后的命令。

BASE 理论强调的最终一致性允许系统中的数据存在中间状态，并认为该状态不影响系统的整体可用性，即**允许多个节点的数据副本存在数据延时**。但是在一定的期限内，应当保证所有副本数据一致，达到数据的最终一致。

总体来说 BASE 理论面向的是大型高并发、可扩展的分布式系统。BASE 提出通过牺牲强一致性来获得可用性，并允许数据短时间内的不一致。在实际场景中，不同业务对数据的一致性要求也不一样，因此衍生出因果一致性、单调读一致性等一致性模型，最终选择要根据使用场景决定。

### 多副本状态机（Replicated state machines）

多副本状态机是指多台机器具有完全相同的状态，并且运行有完全相同的确定性状态机。

通过使用这样的状态机，可以解决很多分布式系统中的容错问题，因为多副本状态机通常可以容忍⌊N/2⌋进程故障，且所有正常运行的副本都完全一致，

所以，可以使用多副本状态机来实现需要避免单点故障的组件，如集中式的选主或是互斥算法中的协调者（coordinator），如图所示：

![高可用“单点”的集中式架构](/images/consensus-algorithm/leader_election.png)

集中式的选主或互斥算法逻辑简单，但最大的问题是协调者的单点故障问题，通过采用多副本状态机来实现协调者实现了高可用的“单点”，回避了单点故障。Google的Chubby服务和类似的开源服务Zookeeper就是这样的例子

虽然有很多不同的多副本状态机实现，但其基本实现模式是类似的：状态机的每个副本上都保存有完全相同的操作日志，保证所有副本状态机按照相同的顺序执行操作，这样由于状态机是确定性的，则一定会得到相同的状态，如下图：

![img](/images/consensus-algorithm/RSM-20211109172154933.jpg)

共识算法的作用就是在这样的场景中保证所有副本状态机上的操作日志具有完全相同的顺序，具体来讲：**如果状态机的任何一个副本在本地状态机上执行了一个操作，则绝对不会有别的副本在操作序列相同位置执行一个不同的操作**。

### Paxos
#### Paxos Overview

- Paxos( [The Part-Time Parliament](http://lamport.azurewebsites.net/pubs/lamport-paxos.pdf) )共识算法由[Leslie Lamport](http://www.lamport.org/)在1989年首次发布，后来由于大多数人不太能接受他的幽默风趣的介绍方法（其实用比喻的方式介绍长篇的理论，确实让人比较难理解），于是在2001年重新写一篇名叫 [Paxos Made Simple](http://lamport.azurewebsites.net/pubs/paxos-simple.pdf) 论文，相当于原始Paxos算法的简化版，主要讲述两阶段共识协议部分。这篇文章与原始文章在讲述Paxos算法上最大的不同就是用的都是计算机术语，看起来也轻松很多
- Paxos算法是分布式系统中的一个共识算法家族，也是第一个有完整数学证明的共识算法
- "世界上只有两种分布式共识算法，一种是Paxos算法，另一种是类Paxos算法"
- 现在比较流行的zab和raft算法也是基于Paxos算法设计的

#### Basic Paxos

1. 角色

   - **提议者（Proposer）**：发出提案（Proposal）。Proposal 信息包括提案编号 (Proposal ID) 和提议的值 (Value)

   - **决策者（Acceptor）**：对每个 Proposal 进行投票，若 Proposal 获得多数 Acceptor 的接受，则称该 Proposal 被批准
   - **学习者（Learner）**：不参与决策，从 Proposers/Acceptors 学习、记录最新达成共识的提案（Value）

2. 算法介绍

   ![image-20211110142025398](/images/consensus-algorithm//image-20211110142025398.png)

   ![image-20211110142043783](/images/consensus-algorithm//image-20211110142043783.png)

   - Prepare:
     - Proposer 选择一个提案编号 N，然后向 Acceptor 广播编号为 N 的 Prepare 请求；
     - 如果 Acceptor 收到一个编号为 N 的 Prepare 请求，且 N 大于它已经响应的所有 Prepare 请求的编号，那么它就会保证不再响应任何编号小于 N 的提案，同时将它已经通过的最大编号的提案（如果存在的话）回复给 Proposer。
   - Accept:
     - 如果 Proposer 收到来自半数以上 Acceptor 的响应，那么它就会发送包含 (N, value) 的 Accept 请求，这里的 value 是收到的响应中编号最大的提案值，如果所有的响应都不包含提案，那么它是客户端发送的值；
     - 如果 Acceptor 收到一个针对编号 N 的提案的 Accept 请求，只要它还未对编号大于 N 的 Prepare 请求作出响应，它就可以通过这个提案

3. 案例说明

   1. 单个Proposer发起提议

      <img src="https://github.com/vision9527/paxos/raw/main/images/single_proposer.png" alt="single_proposer" style="zoom:40%;" />

   2. 多个Proposer发起提议

      <img src="/images/consensus-algorithm/many_proposer.png" alt="many_proposer" style="zoom:40%;" />

   3. 活锁等待情况（两个或者多个Proposer在Prepare阶段发生互相抢占的情形）

      <img src="/images/consensus-algorithm/live_lock-20211112132559089.png" alt="live_lock" style="zoom:40%;"/>

### Multi Paxos

为了不发生活锁等待，一个简单的方式是让服务器等待一会，如果发生接受失败的情况，必须返回重新开始。在重新开始之前等待一会，让提议能有机会完成。可以让集群下服务器随机的延迟，从而避免所有服务器都处于相同的等待时间下。在Multi-Paxos下，会有些不同，它是通过（leader election）的机制。保证在同一时间下只有一个 提议者（Proposers） 在工作

- Multi-Paxos是通过选主解决了进展性问题（同时也是满足一致性的）
- 在Multi Paxos算法中，选主只是为了解决进展性问题，不会影响一致性，即使出现脑裂Paxos算法也是安全的，只会影响进展性

- 两阶段协议效率太低，可以有优化的空间。在单个Leader的情况下，如果前一次已经accept成功，接下来不再需要prepare阶段，直接进行accept
- 当需要决定多个值时就需要连续执行多次Paxos算法，一般执行一次Paxos算法的过程称作A Paxos Run 或者 A Paxos Instance
- 多个instance可以并发的进行
- Multi Paxos通常是指一类共识算法，不是精确的指定某个共识算法

### ZAB（**ZooKeeper Atomic Broadcast**）

Zookeeper Atomic Broadcast，Zookeeper原子消息广播协议，是为Zookeeper所专门设计的一种支持崩溃恢复的原子广播协议。**ZAB协议并不像Paxos算法那样是一种通用的分布式一致性算法，而是专为Zookeeper所设计的**

1. 集群角色

   - **Leader**：一个ZooKeeper集群同一时间只会有一个实际工作的Leader，它会发起并维护与各Follwer及Observer间的心跳。所有的写操作必须要通过Leader完成再由Leader将写操作广播给其它服务器。
   - **Follower**： 一个ZooKeeper集群可能同时存在多个Follower，它会响应Leader的心跳。Follower可直接处理并返回客户端的读请求，同时会将写请求转发给Leader处理，并且负责在Leader处理写请求时对请求进行投票。
   - **Observer**： 角色与Follower类似，但是无投票权

2. 服务器状态

   - **Looking**：该状态表示集群中不存在群首节点，进入群首选举过程。

   - **Leading**：群首状态，表示该服务器是群首节点。

   - **Following**：跟随者状态，表示该服务器是群首的Follow节点。

     **注意**：服务器默认是Looking状态

3. 节点的持久数据状态

   - **history**: 当前节点接收到的事务提议的log
   - **acceptedEpoch**：follower节点已经接受的leader更改年号的NEWEPOCH提议
   - **currentEpoch**：当前所处的年代
   - **lastZxid**：history中最近接收到的提议的zxid

4. 术语解释

   - **quorum**：集群中超过半数的节点集合

   - **epoch**：相当于Raft算法选主时候的term，可以理解为任期

   - **zxid**：是Zookeeper中的数据对应的事务ID，为了保证事务的顺序一致性，zookeeper采用了递增的事务id号（zxid）来标识事务，所有的提议（proposal）都在被提出的时候加上了zxid，zxid是一个64位的数字，高32位是epoch用来标识leader关系是否改变，每次一个leader被选出来，它都会有一个新的epoch（原来的epoch+1)，低32位用于递增计数
   
     <img src="/images/consensus-algorithm/image-20210828204920161-20210828204921.png" alt="image-20210828204920161" style="zoom:40%;" />
   
5. ZAB协议的四阶段

   1. Phase 0: Leader election（选举阶段）

      节点在一开始都处于选举阶段，只要有一个节点得到超半数节点的票数，它就可以当选准 leader。只有到达 Phase 3 准 leader 才会成为真正的 leader。这一阶段的目的是就是为了选出一个准 leader，然后进入下一个阶段

   2. Phase 1: Discovery（发现阶段）

      这个阶段，followers 跟准 leader 进行通信，同步 followers 最近接收的事务提议。这个一阶段的主要目的是发现当前大多数节点接收的最新提议，并且准 leader 生成新的 epoch，让 followers 接受，更新它们的 acceptedEpoch

      一个 follower 只会连接一个 leader，如果有一个节点 f 认为另一个 follower p 是 leader，f 在尝试连接 p 时会被拒绝，f 被拒绝之后，就会进入 Phase 0

      ![img](/images/consensus-algorithm/15473897584862.png)

   3. Phase 2: Synchronization（同步阶段）
   
      同步阶段主要是利用 leader 前一阶段获得的最新提议历史，同步集群中所有的副本。只有当 quorum 都同步完成，准 leader 才会成为真正的 leader。follower 只会接收 zxid 比自己的 lastZxid 大的提议
   
      ![img](/images/consensus-algorithm/15473897747901.png)
   
   4. Phase 3: Broadcast（广播阶段）
   
      到了这个阶段，Zookeeper 集群才能正式对外提供事务服务，并且 leader 可以进行消息广播。同时如果有新的节点加入，还需要对新节点进行同步
   
      值得注意的是，ZAB 提交事务并不像 2PC 一样需要全部 follower 都 ACK，只需要得到 quorum （超过半数的节点）的 ACK 就可以了
   
      ![img](/images/consensus-algorithm/15473897855814.png)
   
6. Java协议实现

   协议的 Java 版本实现跟上面的定义有些不同，选举阶段使用的是 Fast Leader Election（FLE），它包含了 Phase 1 的发现职责。因为 FLE 会选举拥有最新提议历史的节点作为 leader，这样就省去了发现最新提议的步骤。实际的实现将 Phase 1 和 Phase 2 合并为 Recovery Phase（恢复阶段）。所以，ZAB 的实现只有三个阶段：

   - Fast Leader Election
   - Recovery Phase
   - Broadcast Phase

   1. **Fast Leader Election（FLE）**

      FLE 会选举拥有最新提议历史（lastZxid最大）的节点作为 leader，这样就省去了发现最新提议的步骤。这是基于拥有最新提议的节点也有最新提交记录的前提

      成为Leader条件：

      - 选epoch最大的
      - 如果epoch相等，zxid最大的
      - 如果epoch和zxid都相等，选server id最大（zoo.cfg中的myid）

      节点在选举开始都默认投票给自己，当接收其他节点的选票时，会根据上面的条件更改自己的选票并重新发送选票给其他节点，当有一个节点的得票超过半数，该节点会设置自己的状态为 leading，其他节点会设置自己的状态为 following
      
      ![img](/images/consensus-algorithm/15473897991049.png)
      
   2. **Recovery Phase（恢复阶段）**

      - peerLastZxid：这是 Follower 的最后处理 ZXID
      - minCommittedLog：Leader 服务器的提议缓存队列中 （LinkedList<Proposal>）最小的 ZXID
      - maxCommittedLog：Leader 服务器的提议缓存队列中 （LinkedList<Proposal>）最大的ZXID

      根据这三个参数，就可以确定四种同步方式，分别为：

      - 直接差异化同步（DIFF）
        - 场景：当 minCommittedLog < peerLastZxid < maxCommittedLog 时
      - 先回滚在差异化同步（TRUNC+DIFF）
        - 场景：假如集群有 A、B、C 三台机器，此时 A 是 Leader 但是 A 挂了，在挂之前 A 生成了一个提议假设是：03，然后集群又重新选举 B 为新的 Leader，此时生成的的提议缓存队列为：01~02，B 和 C 进行同步之后，生成新的纪元，ZXID 从 10 开始计数，集群进入广播模式处理了部分请求，假设现在 ZXID 执行到 15 这个值，此时 A 恢复了加入集群，这时候就比较 A 最后提交的 ZXID：peerLastZxid 与 minCommittedLog、maxCommittedLog 的关系。此时虽然符合直接差异化同步：minCommittedLog < peerLastZxid < maxCommittedLog 这样的关系，但是提议缓存队列中却没有这个 ZXID ，这时候就需要先回滚，在进行同步。
      - 仅回滚同步（TRUNC）
        - 场景：这里和先回滚在差异化同步类似，直接回滚就可以。
      - 全量同步（SNAP）
        - 场景：peerLastZxid < minCommittedLog，当远远落后 Leader 的数据时，直接全量同步

      ![img](/images/consensus-algorithm/15473898081005.png)
      
   3. **Broadcast Phase**
   
      ZooKeeper 的消息广播过程类似于两阶段提交，针对客户端的读写事务请求，Leader 会生成对应的事务提案，并为其分配 ZXID，随后将这条提案广播给集群中的其它节点。Follower 节点接收到该事务提案后，会先将其以事务日志的形式写入本地磁盘中，写入成功后会给 Leader 反馈一条 Ack 响应。当 Leader 收到超过半数 Follower 节点的 Ack 响应后，会回复客户端写操作成功，并向集群发送 Commit 消息，将该事务提交。Follower 服务器接收到 Commit 消息后，会完成事务的提交，将数据应用到数据副本中。
      
      在消息广播过程中，Leader 服务器会为每个 Follower 维护一个消息队列，然后将需要广播的提案依次放入队列中，并根据『先入先出』的规则逐一发送消息。因为只要超过半数节点响应就可以认为写操作成功，所以少数的慢节点不会影响整个集群的性能
      
      
      

