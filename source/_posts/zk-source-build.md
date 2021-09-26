---
title: Zookeeper -- 客户端源码解析
date: 2020-01-01
categories:
    - Distributed
    - Zookeeper
tags:
    - Zookeeper
typora-root-url: ../../source
---

## 客户端结构解析

### 客户端结构图

<img src="/images/zk-source-build/20161104212932485.jpeg" alt="Zookeeper Client" style="zoom:80%;" />



### 客户端核心类

zk客户端的核心组件如下：
- ZooKeeper实例 ：客户端入口
- ClientWatcherManager ：客户端Watcher管理器
- HostProvider：客户端地址列表管理器
- ClientCnxn：客户端核心线程。包含两个线程，即SendThread和EventThread。前者是一个I/O线程，主要负责ZooKeeper客户端和服务端之间的网络I/O通信，后者是一个事件线程，主要负责对服务端事件进行处理。
- ClientCnxnSocket：底层Socket通信层，有两个实现ClientCnxnSocketNetty、ClientCnxnSocketNIO

![img](/images/zk-source-build/ef78b098db54fbec2d979e0e7edc23fe276181.png)

## 客户端启动流程

Zookeeper客户端初始化与启动环节，就是Zookeeper对象的实例化过程

- 初始化 ZooKeeper 对象
  - 通过调用 ZooKeeper 的构造方法来实例化一个 ZooKeeper 对象，在初始化过程中， 会创建一个客户端的 Watcher 管理器： ClientWatchManager
- 设置默认Watcher
  - 若在Zookeeper构造方法中传入Watcher对象时，那么Zookeeper就会将该Watcher对象保存在ZKWatcherManager的defaultWatcher中，并作为整个客户端会话期间的默认Watcher
- 设置Zookeeper服务器地址列表
  - 对于构造方法中传入的服务器地址，客户端会将其存放在服务器地址列表管理器HostProvider 中
  - 默认使用StaticHostProvider解析服务端地址
    - Chroot：每个客户端可以设置自己的命名空间，若客户端设置了Chroot，客户端对服务器的任何操作都将被限制在自己的命名空间下，如设置Choot为/app/X，那么该客户端的所有节点路径都是以/app/X为根节点
    - StaticHostProvider将InetSocketAddress列表进行shuffle，形成一个环形循环队列，然后再依次取出服务器地址
- 创建ClientCnxn
  - ZooKeeper 客户端首先会创建一个网络连接器 ClientCnxn, 用来管理客户端与服务器的网络交互。
  - 初始化客户端两个核心队列 outgoingQueue 和 pendingQueue, 分别作为客户端的请求 发送队列和服务端响应的等待队列。ClientCnxn 连接器的底层 I/O 处理器是 ClientCnxnSocket,因此在这一步中，客户端还会同时创建 ClientCnxnSocket 处理器

启动流程图如下：

![img](/images/zk-source-build/b3110ff83e94e0680dc5a266ffa6f603193666.png)

## 会话创建阶段

- 启动 SendThread 、EventThread
- 获取一个服务器地址
  - serverAddress = hostProvider.next(1000);
- 创建TCP连接
  - org.apache.zookeeper.ClientCnxnSocket#connect
- 构造ConnectRequest请求：以ClientCnxnSocketNetty为例，operationComplete中执行sendThread.primeConnection()，构造出一个ConnectRequest请求，该请求代表了客户端试图与服务端创建一个会话。同时，ZooKeeper客户端还会进一步将该请求包装成网络I/O层的Packet对象，放入请求发送队列outgoingQueue中去
- 发送请求：ClientCnxnSocket负责从outgoingQueue中取出一个待发送的Packet对象，将其序列化成ByteBuffer向服务端进行发送

### 客户端网络协议

#### TCP自定义协议栈

基于TCP/IP协议，Zookeeper实现了自己的通信协议来玩按成客户端与服务端、服务端与服务端之间的网络通信，对于请求，主要包含请求头和请求体，对于响应，主要包含响应头和响应体

| len  | 请求头 | 请求体 |
| ---- | ------ | ------ |

| len  | 响应头 | 响应体 |
| ---- | ------ | ------ |

- 请求协议

  ![image-20210926101915851](/images/zk-source-build//image-20210926101915851.png)

  ```java
  class RequestHeader {
  	int xid;
    int type;
  }
  ```

  RequestHeader包含 **xid**、**type**

  -  xid ：代表请求的顺序号，用于保证请求的顺序发送和接收
  - 而 type 代表请求的类型

- 响应协议

  ![image-20210926104109116](/images/zk-source-build//image-20210926104109116.png)

  ```java
  class ReplyHeader {
  	int xid;
    long zxid;
    int err;
  }
  ```

  ReplyHeader 主要包括 **xid** 和 **zxid** 以及 **err** 

  - xid：与请求头中的xid一致
  - zxid：表示分布事务 id ，为了保证事务的顺序一致性，zookeeper采用了递增的事务id号（zxid）来标识事务。所有的提议（proposal）都在被提出的时候加上了zxid。实现中zxid是一个64位的数字，它高32位是epoch用来标识leader关系是否改变，每次一个leader被选出来，它都会有一个新的epoch，标识当前属于那个leader的统治时期。低32位用于递增计数
  - err：是一个错误码，表示当请求处理过程出现异常情况时，就会在错误码中标识出来，常见的包括处理成功（Code.OK）、节点不存在（Code.NONODE）、没有权限（Code.NOAUTH）


#### Packet协议

```java
static class Packet {
	RequestHeader requestHeader;	// 请求头信息
	ReplyHeader replyHeader;		// 响应头信息

	Record request;		// 请求数据
	Record response;	// 响应数据

	AsyncCallback cb;	// 异步回调
  Object ctx;			// 异步回调所需使用的 context

	String clientPath;	// 客户端路径视图
  String serverPath;	// 服务器的路径视图
	boolean finished;	// 是否已经处理完成
    
  ByteBuffer bb;		
  public boolean readOnly;
  WatchRegistration watchRegistration;
  WatchDeregistration watchDeregistration;
	
	// 省略方法逻辑..
}
```

## 核心源码解析

1. 建立网络连接

   ```java
   // org.apache.zookeeper.ZooKeeper#ZooKeeper(java.lang.String, int, org.apache.zookeeper.Watcher, boolean, org.apache.zookeeper.client.HostProvider, org.apache.zookeeper.client.ZKClientConfig)
   public ZooKeeper(
           String connectString,
           int sessionTimeout,
           Watcher watcher,
           boolean canBeReadOnly,
           HostProvider hostProvider,
           ZKClientConfig clientConfig
       ) throws IOException {
           LOG.info(
               "Initiating client connection, connectString={} sessionTimeout={} watcher={}",
               connectString,
               sessionTimeout,
               watcher);
   
           this.clientConfig = clientConfig != null ? clientConfig : new ZKClientConfig();
           this.hostProvider = hostProvider;
           ConnectStringParser connectStringParser = new ConnectStringParser(connectString);
   
           // 创建连接管理器
           cnxn = createConnection(
               connectStringParser.getChrootPath(),
               hostProvider,
               sessionTimeout,
               this.clientConfig,
               watcher,
               getClientCnxnSocket(),
               canBeReadOnly);
           cnxn.start();
       }
   ```

   首先建立一个 Zookeeper 客户端时需要创建一个 Zookeeper 对象，且在这个 Zookeeper 对象创建的过程中会创建一个客户端连接管理器（ClientCnxn），接着在创建 ClientCnxn 的过程中又需要创建一个 ClientCnxnSocket 用于实现客户端间的通信，跟进这个 getClientCnxnSocket 方法

   ```java
   // org.apache.zookeeper.ZooKeeper#getClientCnxnSocket
   private ClientCnxnSocket getClientCnxnSocket() throws IOException {
           // 从配置文件中获取 ClientCnxnSocket 配置信息
           String clientCnxnSocketName = getClientConfig().getProperty(ZKClientConfig.ZOOKEEPER_CLIENT_CNXN_SOCKET);
           // 如果配置文件中没有提供 ClientCnxnSocket 配置信息 或者 配置信息为ClientCnxnSocketNIO 则默认使用 NIO
           if (clientCnxnSocketName == null || clientCnxnSocketName.equals(ClientCnxnSocketNIO.class.getSimpleName())) {
               clientCnxnSocketName = ClientCnxnSocketNIO.class.getName();
           // 如果配置信息为ClientCnxnSocketNetty 则使用 Netty
           } else if (clientCnxnSocketName.equals(ClientCnxnSocketNetty.class.getSimpleName())) {
               clientCnxnSocketName = ClientCnxnSocketNetty.class.getName();
           }
   
           try {
               // 通过反射获取 ClientCnxnSocket 的构造方法
               Constructor<?> clientCxnConstructor = Class.forName(clientCnxnSocketName)
                                                          .getDeclaredConstructor(ZKClientConfig.class);
               // 通过以客户端配置为入参调用构造方法来创建一个 ClientCnxnSocket 实例
               ClientCnxnSocket clientCxnSocket = (ClientCnxnSocket) clientCxnConstructor.newInstance(getClientConfig());
               return clientCxnSocket;
           } catch (Exception e) {
               throw new IOException("Couldn't instantiate " + clientCnxnSocketName, e);
           }
       }
   ```

   getClientCnxnSocket 方法中会选择 ClientCnxnSocket 的实现方式，目前的 Zookeeper 中存在两个实现版本，一个是使用 Java JDK 中的 NIO 实现的 ClientCnxnSocketNIO ，另一个是使用 Netty 实现的 ClientCnxnSocketNetty ，而选择的方式优先根据配置文件中的配置进行选择，如果没有进行配置则默认选择 ClientCnxnSocketNIO 实现版本，之后再通过反射的方式创建其实例对象

   ```java
   // org.apache.zookeeper.ClientCnxnSocketNetty#ClientCnxnSocketNetty
   ClientCnxnSocketNetty(ZKClientConfig clientConfig) throws IOException {
           this.clientConfig = clientConfig;
           // Client only has 1 outgoing socket, so the event loop group only needs
           // a single thread.
     			// 创建一个 eventLoopGroup 用于后面对异步请求的处理
           // 且因为客户端只有一个 outgoing Socket 因此只需要一个线程即可
           eventLoopGroup = NettyUtils.newNioOrEpollEventLoopGroup(1 /* nThreads */);
           initProperties();
       }
   ```

   ```java
   // org.apache.zookeeper.common.NettyUtils#newNioOrEpollEventLoopGroup(int)
   public static EventLoopGroup newNioOrEpollEventLoopGroup(int nThreads) {
           // 如果 Epoll 可用（ Linux ）则优先使用 EpollEventLoopGroup 否则使用 NioEventLoopGroup
           if (Epoll.isAvailable()) {
               return new EpollEventLoopGroup(nThreads);
           } else {
               return new NioEventLoopGroup(nThreads);
           }
       }
   ```

   以 Netty 实现为准，所以选择 ClientCnxnSocketNetty 实现版本，在 ClientCnxnSocketNetty 的构造方法中会选择具体的 EventLoopGroup 的实现，如果是在 Linux 优先选择使用性能更高的 EpollEventLoopGroup 实现，且这里配置的线程数目为一，因此这是典型的单线程Reactor实现

   ```java
   // org.apache.zookeeper.ZooKeeper#createConnection
   ClientCnxn createConnection(
           String chrootPath,
           HostProvider hostProvider,
           int sessionTimeout,
           ZKClientConfig clientConfig,
           Watcher defaultWatcher,
           ClientCnxnSocket clientCnxnSocket,
           boolean canBeReadOnly
       ) throws IOException {
           return new ClientCnxn(
               chrootPath,
               hostProvider,
               sessionTimeout,
               clientConfig,
               defaultWatcher,
               clientCnxnSocket,
               canBeReadOnly);
       }
   ```

   ```java
   // org.apache.zookeeper.ClientCnxn#ClientCnxn(java.lang.String, org.apache.zookeeper.client.HostProvider, int, org.apache.zookeeper.client.ZKClientConfig, org.apache.zookeeper.Watcher, org.apache.zookeeper.ClientCnxnSocket, long, byte[], boolean)
   public ClientCnxn(
           String chrootPath,
           HostProvider hostProvider,
           int sessionTimeout,
           ZKClientConfig clientConfig,
           Watcher defaultWatcher,
           ClientCnxnSocket clientCnxnSocket,
           long sessionId,
           byte[] sessionPasswd,
           boolean canBeReadOnly
       ) throws IOException {
           this.chrootPath = chrootPath;
           this.hostProvider = hostProvider;
           this.sessionTimeout = sessionTimeout;
           this.clientConfig = clientConfig;
           this.sessionId = sessionId;
           this.sessionPasswd = sessionPasswd;
           this.readOnly = canBeReadOnly;
   
           this.watchManager = new ZKWatchManager(
                   clientConfig.getBoolean(ZKClientConfig.DISABLE_AUTO_WATCH_RESET),
                   defaultWatcher);
   
           this.connectTimeout = sessionTimeout / hostProvider.size();
           this.readTimeout = sessionTimeout * 2 / 3;
   
           // 初始化SendThread，管理客户端和服务端之间的网络I/O，依赖于clientCnxnSocket，守护线程
           this.sendThread = new SendThread(clientCnxnSocket);
           // 初始化EventThread，用于事件处理，会被设置为守护线程
           this.eventThread = new EventThread();
           // 初始化超时机制
           initRequestTimeout();
       }
   ```

   经过getClientCnxnSocket，继续看Zookeeper 构造方法中的createConnection方法，本质上是创建了一个ClientCnxn对象，并在 ClientCnxn 的构造方法中创建了 SendThread 发送线程和 EventThread 事件处理线程

   ```java
   // org.apache.zookeeper.ClientCnxn#start
   public void start() {
           // 启动sendThread、eventThread
           sendThread.start();
           eventThread.start();
       }
   ```

   当完成 SendThread 和 EventThread 这两个线程的创建和初始化后，在 Zookeeper 的构造方法中最后会通过 cnxn.start() 方法启动这两个线程

   ```java
   // org.apache.zookeeper.ClientCnxn.SendThread#run
   public void run() {
               // 设置clientCnxnSocket相关属性，sessionId用于 Log and Exception messages
               clientCnxnSocket.introduce(this, sessionId, outgoingQueue);
               //初始化当前时间 now = Time.currentElapsedTime() = System.nanoTime() / 1000000;
               clientCnxnSocket.updateNow();
               // 更新发信、收信时间 this.lastSend = now;this.lastHeard = now;
               clientCnxnSocket.updateLastSendAndHeard();
               int to;
               // 最后ping读写时间
               long lastPingRwServer = Time.currentElapsedTime();
               // 最大send ping时间间隔 10S
               final int MAX_SEND_PING_INTERVAL = 10000; //10 seconds
               InetSocketAddress serverAddress = null;
               // state != CLOSED && state != AUTH_FAILED
               while (state.isAlive()) {
                   try {
                       // clientCnxnSocket 没有连接到服务端
                       if (!clientCnxnSocket.isConnected()) {
                           // don't re-establish connection if we are closing
                           if (closing) {
                               break;
                           }
                           // 如果读写服务器地址不为空，用读写服务器地址
                           if (rwServerAddress != null) {
                               serverAddress = rwServerAddress;
                               rwServerAddress = null;
                           } else {
                               // 挨个访问服务器地址列表里的地址，间隔 1 s
                               serverAddress = hostProvider.next(1000);
                           }
                           onConnecting(serverAddress);
                           // 开始连接
                           startConnect(serverAddress);
                           // Update now to start the connection timer right after we make a connection attempt
                           clientCnxnSocket.updateNow();
                           // 更新Socket最后一次发送以及接收消息的时间
                           clientCnxnSocket.updateLastSendAndHeard();
                       }
   
                       if (state.isConnected()) {
                           // determine whether we need to send an AuthFailed event.
                           if (zooKeeperSaslClient != null) {
                               boolean sendAuthEvent = false;
                               if (zooKeeperSaslClient.getSaslState() == ZooKeeperSaslClient.SaslState.INITIAL) {
                                   try {
                                       zooKeeperSaslClient.initialize(ClientCnxn.this);
                                   } catch (SaslException e) {
                                       LOG.error("SASL authentication with Zookeeper Quorum member failed.", e);
                                       changeZkState(States.AUTH_FAILED);
                                       sendAuthEvent = true;
                                   }
                               }
                               KeeperState authState = zooKeeperSaslClient.getKeeperState();
                               if (authState != null) {
                                   if (authState == KeeperState.AuthFailed) {
                                       // An authentication error occurred during authentication with the Zookeeper Server.
                                       changeZkState(States.AUTH_FAILED);
                                       sendAuthEvent = true;
                                   } else {
                                       if (authState == KeeperState.SaslAuthenticated) {
                                           sendAuthEvent = true;
                                       }
                                   }
                               }
   
                               if (sendAuthEvent) {
                                   eventThread.queueEvent(new WatchedEvent(Watcher.Event.EventType.None, authState, null));
                                   if (state == States.AUTH_FAILED) {
                                       eventThread.queueEventOfDeath();
                                   }
                               }
                           }
                           to = readTimeout - clientCnxnSocket.getIdleRecv();
                       } else {
                           to = connectTimeout - clientCnxnSocket.getIdleRecv();
                       }
   
                       // 连接超时
                       if (to <= 0) {
                           String warnInfo = String.format(
                               "Client session timed out, have not heard from server in %dms for session id 0x%s",
                               clientCnxnSocket.getIdleRecv(),
                               Long.toHexString(sessionId));
                           LOG.warn(warnInfo);
                           throw new SessionTimeoutException(warnInfo);
                       }
                       if (state.isConnected()) {
                           //1000(1 second) is to prevent race condition missing to send the second ping
                           //also make sure not to send too many pings when readTimeout is small
                           int timeToNextPing = readTimeout / 2
                                                - clientCnxnSocket.getIdleSend()
                                                - ((clientCnxnSocket.getIdleSend() > 1000) ? 1000 : 0);
                           //send a ping request either time is due or no packet sent out within MAX_SEND_PING_INTERVAL
                           if (timeToNextPing <= 0 || clientCnxnSocket.getIdleSend() > MAX_SEND_PING_INTERVAL) {
                               sendPing();
                               clientCnxnSocket.updateLastSend();
                           } else {
                               if (timeToNextPing < to) {
                                   to = timeToNextPing;
                               }
                           }
                       }
   
                       // If we are in read-only mode, seek for read/write server
                       if (state == States.CONNECTEDREADONLY) {
                           long now = Time.currentElapsedTime();
                           int idlePingRwServer = (int) (now - lastPingRwServer);
                           if (idlePingRwServer >= pingRwTimeout) {
                               lastPingRwServer = now;
                               idlePingRwServer = 0;
                               pingRwTimeout = Math.min(2 * pingRwTimeout, maxPingRwTimeout);
                               pingRwServer();
                           }
                           to = Math.min(to, pingRwTimeout - idlePingRwServer);
                       }
   
                       // 处理真正的 I/O 操作
                       clientCnxnSocket.doTransport(to, pendingQueue, ClientCnxn.this);
                   } catch (Throwable e) {
                       if (closing) {
                           // closing so this is expected
                           LOG.warn(
                               "An exception was thrown while closing send thread for session 0x{}.",
                               Long.toHexString(getSessionId()),
                               e);
                           break;
                       } else {
                           LOG.warn(
                               "Session 0x{} for sever {}, Closing socket connection. "
                                   + "Attempting reconnect except it is a SessionExpiredException.",
                               Long.toHexString(getSessionId()),
                               serverAddress,
                               e);
   
                           // At this point, there might still be new packets appended to outgoingQueue.
                           // they will be handled in next connection or cleared up if closed.
                           cleanAndNotifyState();
                       }
                   }
               }
   
               synchronized (state) {
                   // When it comes to this point, it guarantees that later queued
                   // packet to outgoingQueue will be notified of death.
                   cleanup();
               }
               clientCnxnSocket.close();
               if (state.isAlive()) {
                   eventThread.queueEvent(new WatchedEvent(Event.EventType.None, Event.KeeperState.Disconnected, null));
               }
               eventThread.queueEvent(new WatchedEvent(Event.EventType.None, Event.KeeperState.Closed, null));
               ZooTrace.logTraceMessage(
                   LOG,
                   ZooTrace.getTextTraceLevel(),
                   "SendThread exited loop for session: 0x" + Long.toHexString(getSessionId()));
           }
   ```

   ```java
   // org.apache.zookeeper.ClientCnxn.SendThread#startConnect
   private void startConnect(InetSocketAddress addr) throws IOException {
               // initializing it for new connection
               saslLoginFailed = false;
               if (!isFirstConnect) {
                   try {
                       Thread.sleep(ThreadLocalRandom.current().nextLong(1000));
                   } catch (InterruptedException e) {
                       LOG.warn("Unexpected exception", e);
                   }
               }
               // 设置状态为 CONNECTING
               changeZkState(States.CONNECTING);
   
               String hostPort = addr.getHostString() + ":" + addr.getPort();
               MDC.put("myid", hostPort);
               setName(getName().replaceAll("\\(.*\\)", "(" + hostPort + ")"));
               if (clientConfig.isSaslClientEnabled()) {
                   try {
                       if (zooKeeperSaslClient != null) {
                           zooKeeperSaslClient.shutdown();
                       }
                       zooKeeperSaslClient = new ZooKeeperSaslClient(SaslServerPrincipal.getServerPrincipal(addr, clientConfig), clientConfig);
                   } catch (LoginException e) {
                       // An authentication error occurred when the SASL client tried to initialize:
                       // for Kerberos this means that the client failed to authenticate with the KDC.
                       // This is different from an authentication error that occurs during communication
                       // with the Zookeeper server, which is handled below.
                       LOG.warn(
                           "SASL configuration failed. "
                               + "Will continue connection to Zookeeper server without "
                               + "SASL authentication, if Zookeeper server allows it.", e);
                       eventThread.queueEvent(new WatchedEvent(Watcher.Event.EventType.None, Watcher.Event.KeeperState.AuthFailed, null));
                       saslLoginFailed = true;
                   }
               }
               logStartConnect(addr);
               // 调用 ClientCnxnSocket 的 connect 方法尝试连接
               clientCnxnSocket.connect(addr);
           }
   ```

   在 SendThread 的 run 方法中会启动初始化连接的流程，并且最终会调用到 ClientCnxnSocketNetty 的 connect 方法来建立客户端网络通信的连接，netty连接逻辑如下：

   ```java
   // org.apache.zookeeper.ClientCnxnSocketNetty#connect
   void connect(InetSocketAddress addr) throws IOException {
           firstConnect = new CountDownLatch(1);
   
           // 初始化 netty Bootstrap
           Bootstrap bootstrap = new Bootstrap().group(eventLoopGroup) // 设置 eventLoopGroup
                                                .channel(NettyUtils.nioOrEpollSocketChannel()) // 选择合适的 SocketChannel
                                                .option(ChannelOption.SO_LINGER, -1) // 对应套接字选项SO_LINGER
                                                .option(ChannelOption.TCP_NODELAY, true) // 对应套接字选项 TCP_NODELAY
                                                .handler(new ZKClientPipelineFactory(addr.getHostString(), addr.getPort())); // 设置处理器
           bootstrap = configureBootstrapAllocator(bootstrap);
           bootstrap.validate();
   
           // 获取 connectLock
           connectLock.lock();
           try {
               // Netty 异步调用
               connectFuture = bootstrap.connect(addr);
               // 监听并处理返回结果
               connectFuture.addListener(new ChannelFutureListener() {
                   @Override
                   public void operationComplete(ChannelFuture channelFuture) throws Exception {
                       // this lock guarantees that channel won't be assigned after cleanup().
                       boolean connected = false;
                       connectLock.lock();
                       try {
                           if (!channelFuture.isSuccess()) {
                               LOG.warn("future isn't success.", channelFuture.cause());
                               // 连接失败则直接返回
                               return;
                           } else if (connectFuture == null) {
                               LOG.info("connect attempt cancelled");
                               // If the connect attempt was cancelled but succeeded
                               // anyway, make sure to close the channel, otherwise
                               // we may leak a file descriptor.
                               // 如果 connectFuture 为空则证明尝试连接被取消
                               // 但是因为可能已经连接成功了，所以应当确保 channel 被正常关闭
                               channelFuture.channel().close();
                               return;
                           }
                           // setup channel, variables, connection, etc.
                           channel = channelFuture.channel();
   
                           disconnected.set(false);
                           initialized = false;
                           // lenBuffer 仅用于读取传入消息的长度（该 Buffer 长度为 4 byte）
                           lenBuffer.clear();
                           incomingBuffer = lenBuffer;
   
                           // 构建ConnectRequest 设置 Session、之前的观察者和身份验证
                           sendThread.primeConnection();
                           updateNow();
                           updateLastSendAndHeard();
   
                           if (sendThread.tunnelAuthInProgress()) {
                               waitSasl.drainPermits();
                               needSasl.set(true);
                               sendPrimePacket();
                           } else {
                               needSasl.set(false);
                           }
                           connected = true;
                       } finally {
                           connectFuture = null;
                           connectLock.unlock();
                           if (connected) {
                               LOG.info("channel is connected: {}", channelFuture.channel());
                           }
                           // need to wake on connect success or failure to avoid
                           // timing out ClientCnxn.SendThread which may be
                           // blocked waiting for first connect in doTransport().
                           // 唤醒发送线程中的发送逻辑（向 outgoingQueue 中添加一个 WakeupPacket 空包）
                           wakeupCnxn();
                           // 避免 ClientCnxn 中的 SendThread 在 doTransport() 中等待第一次连接而被阻塞并最终超时
                           firstConnect.countDown();
                       }
                   }
               });
           } finally {
               // 释放connectLock
               connectLock.unlock();
           }
       }
   ```

   connect方法注意点：

   - 设置 Bootstrap 的Handler为 ZKClientPipelineFactory，准确来说是 ZKClientHandler（如下）；

     ```java
     protected void initChannel(SocketChannel ch) throws Exception {
                 ChannelPipeline pipeline = ch.pipeline();
                 if (clientConfig.getBoolean(ZKClientConfig.SECURE_CLIENT)) {
                     initSSL(pipeline);
                 }
                 pipeline.addLast("handler", new ZKClientHandler());
             }
     ```

   - 初始化设置 incomingBuffer = lenBuffer，保证第一次读入的是数据包中真实数据的长度（首部 4byte ByteBuffer）

   - 完成连接后需要通过 wakeupCnxn() 方法来唤醒发送线程的发送逻辑（实质是发送一个空的 WakeupPacket）
   
2. SendThread 从 outgoingQueue 获取并发送 Packet

   ```java
   // org.apache.zookeeper.ClientCnxn.SendThread#run
   public void run() {
   	while (state.isAlive()) {
       	try {
   			if (!clientCnxnSocket.isConnected()) {
               	// 连接服务端逻辑..
   			}
   			// 省略部分代码..
   
   			// 发送 outgoingQueue 中的数据包并将已发送的数据包转移到 PendingQueue 中
         clientCnxnSocket.doTransport(to, pendingQueue, ClientCnxn.this);
           	
         // 省略部分代码..
   		} 
   	}
   ```

   当完成了客户端连接后即可进入到请求发送的逻辑中，客户端发送请求的逻辑主要位于 ClientCnxn 的 SendThread 线程中，在初始化时我们已经启动了该线程，所以当连接建立完成后会通过调用 clientCnxnSocket （ ClientCnxnSocketNetty ）的 **doTransport** 方法发送位于 outgoingQueue 中的 Packet 请求

   ```java
   // org.apache.zookeeper.ClientCnxnSocketNetty#doTransport
   void doTransport(
           int waitTimeOut,
           Queue<Packet> pendingQueue,
           ClientCnxn cnxn) throws IOException, InterruptedException {
           try {
               // 该线程方法会等待连接的建立且超时即返回
               if (!firstConnect.await(waitTimeOut, TimeUnit.MILLISECONDS)) {
                   return;
               }
               Packet head = null;
               if (needSasl.get()) {
                   if (!waitSasl.tryAcquire(waitTimeOut, TimeUnit.MILLISECONDS)) {
                       return;
                   }
               } else {
                   // 从 outgoingQueue 队列中获取要发送的 Packet
                   head = outgoingQueue.poll(waitTimeOut, TimeUnit.MILLISECONDS);
               }
               // check if being waken up on closing.
               // 检查当前是否正处于关闭流程中
               if (!sendThread.getZkState().isAlive()) {
                   // adding back the packet to notify of failure in conLossPacket(). 添加数据包以通知conLossPacket()中的失败
                   addBack(head);
                   return;
               }
               // channel disconnection happened
               // 当通道断开时
               if (disconnected.get()) {
                   addBack(head);
                   throw new EndOfStreamException("channel for sessionid 0x" + Long.toHexString(sessionId) + " is lost");
               }
               if (head != null) {
                   // 调用 doWrite 方法执行实际的发送数据操作
                   doWrite(pendingQueue, head, cnxn);
               }
           } finally {
               updateNow();
           }
       }
   ```

   在 doTransport 方法中首先会 await 等待连接建立，并且在超时后会立即返回（因此在连接建立后需要第一时间唤醒该线程以避免其超时返回），之后会从 outgoingQueue 中取出待发送的 Packet ，并在进行一系列验证后通过 doWrite 方法来实际发送该 Packet 

   ```java
   private void doWrite(Queue<Packet> pendingQueue, Packet p, ClientCnxn cnxn) {
           updateNow();
           boolean anyPacketsSent = false;
           while (true) {
               // 跳过处理 WakeupPacket 数据包
               if (p != WakeupPacket.getInstance()) {
                   if ((p.requestHeader != null)
                       && (p.requestHeader.getType() != ZooDefs.OpCode.ping)
                       && (p.requestHeader.getType() != ZooDefs.OpCode.auth)) {
                       p.requestHeader.setXid(cnxn.getXid());
                       synchronized (pendingQueue) {
                           // 将该 Packet 添加到 pendingQueue 队列中
                           pendingQueue.add(p);
                       }
                   }
                   // 只发送数据包到通道，而不刷新通道
                   sendPktOnly(p);
                   // 记录本轮存在需要被发送的数据
                   anyPacketsSent = true;
               }
               if (outgoingQueue.isEmpty()) {
                   break;
               }
               // 从outgoingQueue 队列获取 Packet
               p = outgoingQueue.remove();
           }
           // TODO: maybe we should flush in the loop above every N packets/bytes?
           // But, how do we determine the right value for N ...
           // 如果本轮存在需要被发送的数据，则调用 flush 刷新 Netty 通道
           if (anyPacketsSent) {
               channel.flush();
           }
       }
   ```

   在 doWrite 方法中会在验证该 Packet 非 WakeupPacket 后为其设置请求头中的 xid ，并将其添加到 pendingQueue 中，最后通过 sendPktOnly 方法将其发送到通道中（暂不刷新通道，方法代码如下），然后如果 outgoingQueue 中仍存在待发送的 Packet 则继续重复执行添加 pendingQueue 并发送的逻辑，当 outgoingQueue 中的 Packet 全部处理完成后调用 channel.flush() 刷新通道，将本轮数据一起发送

   ```java
   // org.apache.zookeeper.ClientCnxnSocketNetty#sendPktOnly
   private ChannelFuture sendPktOnly(Packet p) {
   	// 仅发送数据包到通道，而不调用 flush() 方法刷新通道
       return sendPkt(p, false);
   }
   
   // org.apache.zookeeper.ClientCnxnSocketNetty#sendPkt
   private ChannelFuture sendPkt(Packet p, boolean doFlush) {
   	// 创建 ByteBuffer
       p.createBB();
       updateLastSend();
       // 将 ByteBuffer 转化为 Netty 的 ByteBuf
       final ByteBuf writeBuffer = Unpooled.wrappedBuffer(p.bb);
       final ChannelFuture result = doFlush
               ? channel.writeAndFlush(writeBuffer)
               : channel.write(writeBuffer);
       result.addListener(onSendPktDoneListener);
       return result;
   }
   ```

3. 同步RPC调用流程（Create Api）

   **同步Create Api入口：**

   ```java
   // org.apache.zookeeper.ZooKeeper#create(java.lang.String, byte[], java.util.List<org.apache.zookeeper.data.ACL>, org.apache.zookeeper.CreateMode)
   public String create(
           final String path,
           byte[] data,
           List<ACL> acl,
           CreateMode createMode) throws KeeperException, InterruptedException {
           final String clientPath = path;
           // 相关信息验证
           PathUtils.validatePath(clientPath, createMode.isSequential());
           EphemeralType.validateTTL(createMode, -1);
           validateACL(acl);
   
           final String serverPath = prependChroot(clientPath);
   
           // 创建 Request 请求包和 Response 响应包
           RequestHeader h = new RequestHeader();
           h.setType(createMode.isContainer() ? ZooDefs.OpCode.createContainer : ZooDefs.OpCode.create);
           CreateRequest request = new CreateRequest();
           CreateResponse response = new CreateResponse();
           request.setData(data);
           request.setFlags(createMode.toFlag());
           request.setPath(serverPath);
           request.setAcl(acl);
           // 提交请求并接收返回头
           ReplyHeader r = cnxn.submitRequest(h, request, response, null);
           // 处理异常
           if (r.getErr() != 0) {
               throw KeeperException.create(KeeperException.Code.get(r.getErr()), clientPath);
           }
           // 返回结果
           if (cnxn.chrootPath == null) {
               return response.getPath();
           } else {
               return response.getPath().substring(cnxn.chrootPath.length());
           }
       }
   ```

   同步Api中 Create 方法的逻辑可以概括为以下五步:

   - 验证相关信息的有效性（包括验证客户端的路径以及创建模式的选择）
   - 创建 **Request** 请求包和 **Response** 响应包，并为 Request 请求包填充数据
   - 通过调用 **ClientCnxn** 的 **submitRequest** 方法提交请求并接收请求结果
   - 处理请求结果中的异常
   - 返回请求结果

   ```java
   // org.apache.zookeeper.ClientCnxn#submitRequest(org.apache.zookeeper.proto.RequestHeader, org.apache.jute.Record, org.apache.jute.Record, org.apache.zookeeper.ZooKeeper.WatchRegistration, org.apache.zookeeper.WatchDeregistration)
   public ReplyHeader submitRequest(
           RequestHeader h,
           Record request,
           Record response,
           WatchRegistration watchRegistration,
           WatchDeregistration watchDeregistration) throws InterruptedException {
           ReplyHeader r = new ReplyHeader();
           // 根据 Request 数据和 Response 数据打包创建 Packet
           Packet packet = queuePacket(
               h,
               r,
               request,
               response,
               null,
               null,
               null,
               null,
               watchRegistration,
               watchDeregistration);
           synchronized (packet) {
               if (requestTimeout > 0) {
                   // Wait for request completion with timeout
                   // 等待请求完成超时
                   waitForPacketFinish(r, packet);
               } else {
                   // Wait for request completion infinitely
                   // 等待请求完成
                   while (!packet.finished) {
                       packet.wait();
                   }
               }
           }
           if (r.getErr() == Code.REQUESTTIMEOUT.intValue()) {
               // 如果请求超时则清空 outgoingQueue 和 pendingQueue
               sendThread.cleanAndNotifyState();
           }
           return r;
       }
   ```

   首先会调用 queuePacket 方法创建 Packet 并将其入队 outgoing ，之后同步该 Packet，最后根据是否设置了超时时间来选择是否使用超时逻辑，如果设置了超时时间，当请求在超时时间内未完成即返回并清空相关队列（outgoingQueue 和 pendingQueue），而如果未设置超时时间则该线程无限期的 wait 在该 Packet 直至接收到该请求的响应（在接收到请求的响应后该线程会被 notify）

   ```java
   public Packet queuePacket(
           RequestHeader h,
           ReplyHeader r,
           Record request,
           Record response,
           AsyncCallback cb,
           String clientPath,
           String serverPath,
           Object ctx,
           WatchRegistration watchRegistration,
           WatchDeregistration watchDeregistration) {
           Packet packet = null;
   
           // Note that we do not generate the Xid for the packet yet. It is
           // generated later at send-time, by an implementation of ClientCnxnSocket::doIO(),
           // where the packet is actually sent.
           // 创建一个 Packet 实例并将相关数据填入
           packet = new Packet(h, r, request, response, watchRegistration);
           packet.cb = cb;
           packet.ctx = ctx;
           packet.clientPath = clientPath;
           packet.serverPath = serverPath;
           packet.watchDeregistration = watchDeregistration;
           // The synchronized block here is for two purpose:
           // 1. synchronize with the final cleanup() in SendThread.run() to avoid race
           // 2. synchronized against each packet. So if a closeSession packet is added,
           // later packet will be notified.
           // 同步状态
           synchronized (state) {
               if (!state.isAlive() || closing) {
                   // 如果当前连接已断开或者正在关闭则返回相应的错误信息
                   conLossPacket(packet);
               } else {
                   // If the client is asking to close the session then
                   // mark as closing
                   // 如果客户端要求关闭会话，则将其状态标记为正在关闭（Closing）
                   if (h.getType() == OpCode.closeSession) {
                       closing = true;
                   }
                   // 如果请求超时则清空 outgoingQueue 和 pendingQueue
                   outgoingQueue.add(packet);
               }
           }
           // 唤醒发送线程发送 outgoing 队列中的 Packet（Netty 中为空实现）
           sendThread.getClientCnxnSocket().packetAdded();
           return packet;
       }
   ```

   在 queuePacket 方法中会创建一个 Packet 实例，并将入参中的 request 请求包和 response 响应包等数据填充到该 Packet 中。但需要注意的是，到目前为止还没有为包生成 Xid ，它是在稍后发送时由 ClientCnxnSocket::doIO() 实现生成的，因为 Packet 实际上是在那里被发送的。然后会同步在状态值 state 上，这里之所以要同步在该状态上的原因有两点：

   - 同步 SendThread.run() 中的 cleanup() 操作以避免竞争
   - 通过对每个包进行同步，如果一个 closeSession 包被添加，后面的包都会被通知

   到这里为止（ **Packet 入队 outgoingQueue 且线程 wait** ）同步版本的 Create API 实现第一部分已经分析完成，下面我们来大概总结一下主要的流程：

   - 首先在 Zookeeper 的 Create() 方法中根据入参创建 Request 请求包和 Response 响应包
   - 调用 ClientCnxn 的 submitRequest() 方法提交该请求，在 submitRequest() 方法中会调用 queuePacket() 方法
   - 在 queuePacket() 方法中将入参中的 Request 请求包和 Response 响应包以及其它信息封装为 Packet ，然后将其入队 outgoingQueue 并唤醒发送逻辑
   - 返回到 ClientCnxn 的 submitRequest() 方法中，根据是否设置超时时间选择不同的逻辑来将该线程 wait
   
   **处理响应并出队 pendingQueue（且 Packet.notifyAll）**
   
   ```java
   // org.apache.zookeeper.ClientCnxnSocketNetty.ZKClientHandler#channelRead0
   protected void channelRead0(ChannelHandlerContext ctx, ByteBuf buf) throws Exception {
               updateNow();
               while (buf.isReadable()) {
                   if (incomingBuffer.remaining() > buf.readableBytes()) {
                       // 如果 incomingBuffer 中剩余的空间大于 ByteBuf 中可读数据长度
                       // 重置 incomingBuffer 中的 limit 为 incomingBuffer 当前的 position 加上 ByteBuf 中可读的数据长度
                       int newLimit = incomingBuffer.position() + buf.readableBytes();
                       incomingBuffer.limit(newLimit);
                   }
                   // 将 ByteBuf 中的数据读入到 incomingBuffer（ ByteBuffer）中
                   buf.readBytes(incomingBuffer);
                   incomingBuffer.limit(incomingBuffer.capacity());
   
                   if (!incomingBuffer.hasRemaining()) {
                       incomingBuffer.flip();
                       if (incomingBuffer == lenBuffer) {
                           recvCount.getAndIncrement();
                           // 当 incomingBuffer 等于 lenBuffer 时首先读取数据包中数据的长度 4byte
                           readLength();
                       } else if (!initialized) {
                           // 如果未进行初始化则首先读取连接结果
                           readConnectResult();
                           // 重置 lenBuffer 并重新初始化 incomingBuffer 为 lenBuffer 来读取数据包中真正数据的长度
                           lenBuffer.clear();
                           incomingBuffer = lenBuffer;
                           initialized = true;
                           updateLastHeard();
                       } else {
                           // 读取数据包中真正的数据
                           sendThread.readResponse(incomingBuffer);
                           // 重置 lenBuffer 并重新初始化 incomingBuffer 为 lenBuffer 来读取数据包中真正数据的长度
                           lenBuffer.clear();
                           incomingBuffer = lenBuffer;
                           updateLastHeard();
                       }
                   }
               }
               // 唤醒发送逻辑
               wakeupCnxn();
               // Note: SimpleChannelInboundHandler releases the ByteBuf for us
               // so we don't need to do it.
           }
   ```
   
   首先在初始化连接的过程中（connect 方法中）我们就已将 incomingBuffer 设置为 lenBuffer（4 byte ByteBuffer），因此当数据到达时 incomingBuffer 会先将 ByteBuf 中的前 4byte 数据读入，然后调用 readLength 方法来获取这 4byte 所代表的 int 数值（真实数据的长度），之后再创建一个新的长度为真实数据长度的 ByteBuffer 赋值给 incomingBuffer，这样在下一轮的读取过程中 incomingBuffer 就可以从 ByteBuf 中一次性完整的读出所有的真实数据，最后调用 readResponse 方法来处理读取到的真实数据
   
   ```java
   // org.apache.zookeeper.ClientCnxn.SendThread#readResponse
   void readResponse(ByteBuffer incomingBuffer) throws IOException {
               ByteBufferInputStream bbis = new ByteBufferInputStream(incomingBuffer);
               BinaryInputArchive bbia = BinaryInputArchive.getArchive(bbis);
               // 创建临时响应头
               ReplyHeader replyHdr = new ReplyHeader();
   
               // 解析数据包中的数据填充临时响应头，然后根据临时响应头中的 xid 进行分类处理
               replyHdr.deserialize(bbia, "header");
               switch (replyHdr.getXid()) {
               case PING_XID:
                   LOG.debug("Got ping response for session id: 0x{} after {}ms.",
                       Long.toHexString(sessionId),
                       ((System.nanoTime() - lastPingSentNs) / 1000000));
                   // xid == -2 为心跳包
                   // 心跳包不做处理直接返回
                   return;
                 case AUTHPACKET_XID:
                     // xid == -4 为认证包
                   LOG.debug("Got auth session id: 0x{}", Long.toHexString(sessionId));
                   if (replyHdr.getErr() == KeeperException.Code.AUTHFAILED.intValue()) {
                       changeZkState(States.AUTH_FAILED);
                       eventThread.queueEvent(new WatchedEvent(Watcher.Event.EventType.None,
                           Watcher.Event.KeeperState.AuthFailed, null));
                       eventThread.queueEventOfDeath();
                   }
                 return;
               case NOTIFICATION_XID:
                   // xid == -1 为通知包
                   LOG.debug("Got notification session id: 0x{}",
                       Long.toHexString(sessionId));
                   WatcherEvent event = new WatcherEvent();
                   event.deserialize(bbia, "response");
   
                   // convert from a server path to a client path
                   if (chrootPath != null) {
                       String serverPath = event.getPath();
                       if (serverPath.compareTo(chrootPath) == 0) {
                           event.setPath("/");
                       } else if (serverPath.length() > chrootPath.length()) {
                           event.setPath(serverPath.substring(chrootPath.length()));
                        } else {
                            LOG.warn("Got server path {} which is too short for chroot path {}.",
                                event.getPath(), chrootPath);
                        }
                   }
   
                   WatchedEvent we = new WatchedEvent(event);
                   LOG.debug("Got {} for session id 0x{}", we, Long.toHexString(sessionId));
                   eventThread.queueEvent(we);
                   return;
               default:
                   break;
               }
   
               // If SASL authentication is currently in progress, construct and
               // send a response packet immediately, rather than queuing a
               // response as with other packets.
               if (tunnelAuthInProgress()) {
                   GetSASLRequest request = new GetSASLRequest();
                   request.deserialize(bbia, "token");
                   zooKeeperSaslClient.respondToServer(request.getToken(), ClientCnxn.this);
                   return;
               }
   
               Packet packet;
               synchronized (pendingQueue) {
                   // 如果 pendingQueue 为空则直接抛异常，否则出队一个 Packet
                   if (pendingQueue.size() == 0) {
                       throw new IOException("Nothing in the queue, but got " + replyHdr.getXid());
                   }
                   packet = pendingQueue.remove();
               }
               /*
                * Since requests are processed in order, we better get a response
                * to the first request!
                */
               // 由于请求是按顺序处理的，所以获得对第一个请求的响应
               try {
                   // 如果 pendingQueue 刚刚出队的 Packet 不是当前响应所对应的 Packet 则证明出现异常
                   if (packet.requestHeader.getXid() != replyHdr.getXid()) {
                       packet.replyHeader.setErr(KeeperException.Code.CONNECTIONLOSS.intValue());
                       throw new IOException("Xid out of order. Got Xid " + replyHdr.getXid()
                                             + " with err " + replyHdr.getErr()
                                             + " expected Xid " + packet.requestHeader.getXid()
                                             + " for a packet with details: " + packet);
                   }
   
                   // 填充 Packet 响应头数据
                   packet.replyHeader.setXid(replyHdr.getXid());
                   packet.replyHeader.setErr(replyHdr.getErr());
                   packet.replyHeader.setZxid(replyHdr.getZxid());
                   // 更新最后处理的 zxid
                   if (replyHdr.getZxid() > 0) {
                       lastZxid = replyHdr.getZxid();
                   }
                   // 如果 Packet 中存在 Response 响应包（数据为空）且响应头解析未出现错误则继续解析响应体数据
                   if (packet.response != null && replyHdr.getErr() == 0) {
                       packet.response.deserialize(bbia, "response");
                   }
   
                   LOG.debug("Reading reply session id: 0x{}, packet:: {}", Long.toHexString(sessionId), packet);
               } finally {
                   // 完整响应数据解析后调用
                   finishPacket(packet);
               }
           }
   ```
   
   readResponse 方法首先从刚刚读入数据的 ByteBuffer 中解析出一个临时响应头，然后根据这个临时响应头中的 xid 来进行分类处理， 当处理完成后会从 pendingQueue 中出队一个 Packet，这个 Packet 正常来说应当是我们之前发送最后一个请求后入队的那个 Packet （请求顺序性），因此判断这个出队的 Packet 的 xid 是否等于当前正在处理的这个请求中的 Packet 的 xid ，如果不是则证明出现了丢包或断连等问题，所以向临时响应头中添加一个错误信息，然后将临时响应头中的数据填充到刚刚出队的那个 Packet 的 ReplyHeader 响应头中并更新最后处理的 zxid 属性值（ lastZxid ），最终如果确认该 Packet 中存在 Response（需要返回响应信息）并且在解析响应头的过程中未发现错误，则开始从 ByteBuffer 中解析出响应体并赋给 Packet 的 Response 属性，当全部处理完成时，最终调用 finishPacket 方法完成 ByteBuffer 的 Response 解析
   
   ```java
   // org.apache.zookeeper.ClientCnxn#finishPacket
   protected void finishPacket(Packet p) {
           int err = p.replyHeader.getErr();
           if (p.watchRegistration != null) {
               p.watchRegistration.register(err);
           }
           // Add all the removed watch events to the event queue, so that the
           // clients will be notified with 'Data/Child WatchRemoved' event type.
           // watch事件处理
           if (p.watchDeregistration != null) {
               Map<EventType, Set<Watcher>> materializedWatchers = null;
               try {
                   materializedWatchers = p.watchDeregistration.unregister(err);
                   for (Entry<EventType, Set<Watcher>> entry : materializedWatchers.entrySet()) {
                       Set<Watcher> watchers = entry.getValue();
                       if (watchers.size() > 0) {
                           queueEvent(p.watchDeregistration.getClientPath(), err, watchers, entry.getKey());
                           // ignore connectionloss when removing from local
                           // session
                           p.replyHeader.setErr(Code.OK.intValue());
                       }
                   }
               } catch (KeeperException.NoWatcherException nwe) {
                   p.replyHeader.setErr(nwe.code().intValue());
               } catch (KeeperException ke) {
                   p.replyHeader.setErr(ke.code().intValue());
               }
           }
           if (p.cb == null) {
               // 如果 Packet 中不存在方法回调（同步 API）
               synchronized (p) {
                   // 设置 Packet 处理完成
                   p.finished = true;
                   // 唤醒所有 wait 在该 Packet 上的线程
                   p.notifyAll();
               }
           } else {
               // 如果 Packet 中不存在方法回调（异步 API），先设置 Packet 处理完成
               p.finished = true;
               // 进入异步 Packet 的处理逻辑
               eventThread.queuePacket(p);
           }
       }
   ```
   
   finishPacket 方法在响应处理完成后就会被调用，在这个方法中首先会对 Watch 事件进行处理，然后判断当前 Packet 中是否存在回调方法（本次调用是同步还是异步），如果不存在回调方法则证明本次调用为同步调用，因此更新 Packet 的 finished 状态后通过 Packet 的 notifyAll 方法唤醒所有 wait 在该 Packet 上的线程（wait 逻辑位于 ClientCnxn 的 submitRequest 方法），而如果存在回调方法，则应通过调用 EventThread 的 queuePacket 方法进入对于异步回调的处理逻辑中


4. 异步RPC调用流程（Create Api）
   异步Create Api入口
   ```java
   // org.apache.zookeeper.ZooKeeper#create(java.lang.String, byte[], java.util.List<org.apache.zookeeper.data.ACL>, org.apache.zookeeper.CreateMode, org.apache.zookeeper.AsyncCallback.StringCallback, java.lang.Object)
   public void create(
           final String path,
           byte[] data,
           List<ACL> acl,
           CreateMode createMode,
           StringCallback cb,
           Object ctx) {
           final String clientPath = path;
           // 相关信息验证（与同步模式相同）
           PathUtils.validatePath(clientPath, createMode.isSequential());
           EphemeralType.validateTTL(createMode, -1);
   
           final String serverPath = prependChroot(clientPath);
           // 创建 Request 请求包和 Response 响应包（与同步模式相同）
           RequestHeader h = new RequestHeader();
           h.setType(createMode.isContainer() ? ZooDefs.OpCode.createContainer : ZooDefs.OpCode.create);
           CreateRequest request = new CreateRequest();
           CreateResponse response = new CreateResponse();
           ReplyHeader r = new ReplyHeader();
           request.setData(data);
           request.setFlags(createMode.toFlag());
           request.setPath(serverPath);
           request.setAcl(acl);
           // 直接调用 queuePacket 方法创建 Packet 并入队 outgoingQueue
           cnxn.queuePacket(h, r, request, response, cb, clientPath, serverPath, ctx, null);
       }
   ```
   
   异步模式的 API 和同步版 API 是大体相同的，只不过在异步版本的 API 中仅需要调用 queuePacket 方法创建 Packet 并入队 outgoingQueue ，然后直接返回即可，而不需要再在 submitRequest 方法中 wait 等待请求响应的返回
   
   ```java
   // org.apache.zookeeper.ClientCnxn.EventThread#queuePacket
   public void queuePacket(Packet packet) {
               if (wasKilled) {
                   // EventThread 在接收到 eventOfDeath 后 wasKilled 将被设为 true
                   synchronized (waitingEvents) {
                       if (isRunning) {
                           // 如果 EventThread 仍在运行（isRunning == true）则将 Packet 入队 waitingEvents
                           waitingEvents.add(packet);
                       } else {
                           // 否则直接调用 processEvent 方法处理该 Packet
                           processEvent(packet);
                       }
                   }
               } else {
                   // 如果 EventThread 线程正常运行则直接将 Packet 入队 waitingEvents
                   waitingEvents.add(packet);
               }
           }
   ```
   
   在接收并处理 Response 的过程中同步版和异步版的 API 前面的处理逻辑都是完全相同的，差异之处在于在 finishPacket 方法中同步版调用会直接唤醒所有 wait 在该 Packet 上面的线程然后返回，而对于异步版本则会调用到 queuePacket 方法来对响应做进一步的处理
   
   queuePacket 方法主要执行的就是将 Packet 入队 waitingEvents 的逻辑，但是需要注意的是对于 EventThread 存在两个标志量（下文会细讲），且当 wasKilled 为 true 时并不是意味着 EventThread 已经完全不能处理 Packet 了，还需要再次判断 isRunning 来确定当前 EventThread 是否真的已经停止运行了，如果当前 wasKilled 为 true 且 isRunning 为 false 则证明 EventThread 已经真正的结束了，所以该方法会自己调用 processEvent 方法来处理该 Packet
   
   当我们在 queuePacket 方法中将 Packet 入队 waitingEvents 后，在 ClientCnxn 的内部类（线程）EventThread 中会通过 run 方法不断取出队列中的 Packet ，然后调用 processEvent 方法进行处理。这里设计很巧妙的就是对于关闭该线程时的操作，在该线程中使用了两个标志量 wasKilled 和 isRunning ，当外部将要关闭它时会通过发送类型为 eventOfDeath 的 Packet 先设置 wasKilled 为 true，此时进入关闭的第一阶段。EventThread 得到该关闭消息后开始进行扫尾工作，在每次处理完一个 Packet 后就会判断 waitingEvents 中是否还存在未处理的 Packet ，如果存在就继续处理，如果不存在就将 isRunning 设置为 false 并跳出循环，此时标志着 EventThread 已经完成了扫尾工作，可以正常关闭了。因此，EventThread 可以安全的进入到最后一个线程的关闭阶段。这样的三阶段关闭流程保证了数据的安全性，保证了 EventThread 不会在 waitingEvents 还存在数据时就关闭而导致数据丢失，同时也正是因为这样，当通过 queuePacket 方法向 waitingEvents 中添加元素时，就算 wasKilled 已经为 true 了，但只要 isRunning 还为 true 就证明 waitingEvents 中还存在数据既 EventThread 还可以处理数据，所以仍然可以放心的将 Packet 入队 waitingEvents 来交给 EventThread 处理，且不会发生数据丢失的情况
   
   ```java
   // ClientCnxn.EventThread.java
   private void processEvent(Object event) {
   	try {
   		// 重构后的代码，省略巨多各种事件类型的判断和处理逻辑...
   		// 当进行异步 Create 时，事件类型为 CreateResponse 
       	if (p.response instanceof CreateResponse) {
       		// 获取 Packet 中的回调信息
           	StringCallback cb = (StringCallback) p.cb;
           	// 获取 Packet 中的响应体
               CreateResponse rsp = (CreateResponse) p.response;
               if (rc == 0) {
               	cb.processResult(rc, clientPath, p.ctx,
                   	(chrootPath == null ? rsp.getPath() : rsp.getPath().substring(chrootPath.length())));
   			} else {
   				// 进行方法回调
   				cb.processResult(rc, clientPath, p.ctx, null);
   			}
   		}
   	}
   }
   ```
   
   在 processEvent 方法中会根据传入 Packet 的类型来选择不同的处理逻辑对 Packet 进行处理，因为我们这里分析的是 Create API ，而其对应的响应类型为 CreateResponse ，所以会进入到如上图代码的逻辑中，具体的处理方式也就是获取到 Packet 中所保存的回调方法，然后对其进行回调即可，至此也就完成了整个异步版本的方法调用

## 同步、异步比较
首先经过上面的源码分析我们先总结一下几个比较重要的数据结构和属性：

- outgoingQueue ：保存待发送的 Packet 的队列
- pendingQueue ：保存已发送但还未接收到响应的 Packet 的队列
- waitingEvents ：保存已接收到响应待回调的 Packet 的队列
- EventThread.wasKilled ：外部发送信号终止 EventThread ，但此时可能尚未真正停止
- EventThread.isRunning ：标志着 EventThread 尚在运行（waitingEvents 中还存在未处理的 Packet），当该属性为 false 时证明线程进入终止状态

总结同步版 API 主流程：
- 创建 Packet 并入队 outgoingQueue ，然后线程 wait 在该 Packet 进行等待
- SendThread 从 outgoingQueue 中取出 Packet 后进行发送，并入队 pendingQueue
- 接收响应后从 pendingQueue 中出队 Packet ，然后将响应数据解析到 Packet中
- 解析完成后调用 Packet.notifyAll 方法唤醒所有阻塞在该 Packet 上的线程

总结 异步版 API 主流程：
- 创建 Packet 并入队 outgoingQueue ，然后方法直接返回
- SendThread 从 outgoingQueue 中取出 Packet 后进行发送，并入队 pendingQueue
- 接收响应后从 pendingQueue 中出队 Packet ，然后将响应数据解析到 Packet中
- 解析完成后将该 Packet 入队 waitingEvents ，然后 EventThread 会从 waitingEvents 中取出 Packet 并调用其回调方法

