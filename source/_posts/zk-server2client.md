---
title: Zookeeper -- 服务端与客户端网络通信源码分析
date: 2020-01-05
categories:
    - Distributed
    - Zookeeper
tags:
    - Zookeeper
typora-root-url: ../../source
---

## 概述

Zookeeper 中服务端的通信又可分为服务端与服务端之间的通信和服务端和客户端之间的通信，本章节着重解析服务端和客户端之间的通信，及源码分析。

## 服务端架构图

![image-zk-framework](/images/zk-server2client/image-zk-framework.png)

## 核心类介绍

zk服务端分为单机模式、集群模式，本章因为着重分析服务端与客户端通信，所以使用单机模式作为源码解析，以避开集群模式相关代码的干扰。

- ZooKeeperServerMain ：ZkServer 核心启动类
- ServerCnxnFactory ：服务端连接管理器工厂（工厂模式）
- NettyServerCnxnFactory ：服务端连接管理器工厂 Netty 实现（ServerCnxnFactory 实现类）
- NettyServerCnxn ：单条连接的服务端连接管理器 Netty 实现
- RequestProcessor ：请求处理器接口，实现该接口类可用作 Request Processor Pipeline 中的节点

## 服务端启动流程

1. 配置文件解析
2. 初始化数据管理器
3. 初始化网络I/O管理器
4. 数据恢复
5. 对外服务

![启动流程图](/images/zk-server2client/5871751-92c0da6dc6ea8287.png)

## 单机模式启动流程概述

1. 配置文件解析
2. 创建并启动历史文件清理器
3. 初始化数据管理器
4. 注册shutdownHandler
5. 启动Admin server
6. 创建并启动网络IO管理器
7. 启动ZooKeeperServer
8. 创建并启动secureCnxnFactory
9. 创建并启动ContainerManager

## 单机启动源码解析

1. 代码入口

   ```java
   // org.apache.zookeeper.server.quorum.QuorumPeerMain#main
   public static void main(String[] args) {
           QuorumPeerMain main = new QuorumPeerMain();
           // 服务端启动入口
     			 try {
       			// 根据命令行参数初始化并运行 Zookeeper 服务端
       			main.initializeAndRun(args);
       		} 
           ...
       }
   ```

2. 配置文件解析

   ```java
   // org.apache.zookeeper.server.quorum.QuorumPeerMain#initializeAndRun
   protected void initializeAndRun(String[] args) throws ConfigException, IOException, AdminServerException {
           // 1.解析配置文件
           QuorumPeerConfig config = new QuorumPeerConfig();
           if (args.length == 1) {
               config.parse(args[0]);
           }
   
           // Start and schedule the the purge task
           // 2.创建并启动历史文件清理器(对事务日志和快照数据文件进行定时清理)
           DatadirCleanupManager purgeMgr = new DatadirCleanupManager(
               config.getDataDir(),
               config.getDataLogDir(),
               config.getSnapRetainCount(),
               config.getPurgeInterval());
           purgeMgr.start();
   
           if (args.length == 1 && config.isDistributed()) {
               // 集群启动
               runFromConfig(config);
           } else {
               LOG.warn("Either no config or no quorum defined in config, running in standalone mode");
               // there is only server in the quorum -- run as standalone
               // 单机启动
               ZooKeeperServerMain.main(args);
           }
       }
   ```

3. 启动流程

   ```java
   // org.apache.zookeeper.server.ZooKeeperServerMain#runFromConfig
   public void runFromConfig(ServerConfig config) throws IOException, AdminServerException {
           LOG.info("Starting server");
           FileTxnSnapLog txnLog = null;
           try {
               try {
                   metricsProvider = MetricsProviderBootstrap.startMetricsProvider(
                       config.getMetricsProviderClassName(),
                       config.getMetricsProviderConfiguration());
               } catch (MetricsProviderLifeCycleException error) {
                   throw new IOException("Cannot boot MetricsProvider " + config.getMetricsProviderClassName(), error);
               }
               ServerMetrics.metricsProviderInitialized(metricsProvider);
               ProviderRegistry.initialize();
               // Note that this thread isn't going to be doing anything else,
               // so rather than spawning another thread, we will just call
               // run() in this thread.
               // create a file logger url from the command line args
               // 3.创建ZooKeeper数据管理器
               txnLog = new FileTxnSnapLog(config.dataLogDir, config.dataDir);
               JvmPauseMonitor jvmPauseMonitor = null;
               if (config.jvmPauseMonitorToRun) {
                   jvmPauseMonitor = new JvmPauseMonitor(config);
               }
               // 创建 Zookeeper 服务端实例
               final ZooKeeperServer zkServer = new ZooKeeperServer(jvmPauseMonitor, txnLog, config.tickTime, config.minSessionTimeout, config.maxSessionTimeout, config.listenBacklog, null, config.initialConfig);
               // 将 Zookeeper 服务端实例与本地事务文件存储进行绑定
               txnLog.setServerStats(zkServer.serverStats());
   
               // Registers shutdown handler which will be used to know the
               // server error or shutdown state changes.
               // 4.注册shutdownHandler,在ZooKeeperServer的状态变化时调用shutdownHandler的handle()
               final CountDownLatch shutdownLatch = new CountDownLatch(1);
               zkServer.registerServerShutdownHandler(new ZooKeeperServerShutdownHandler(shutdownLatch));
   
               // Start Admin server
               // 5.启动Admin server
               adminServer = AdminServerFactory.createAdminServer();
               adminServer.setZooKeeperServer(zkServer);
               adminServer.start();
   
               // 6.创建并启动网络IO管理器
               boolean needStartZKServer = true;
               if (config.getClientPortAddress() != null) {
                   // 通过静态方法 createFactory 创建 ServerCnxnFactory 实例
                   cnxnFactory = ServerCnxnFactory.createFactory();
                   // 根据配置文件中的 ClientPostAddress 配置其客户端端口
                   cnxnFactory.configure(config.getClientPortAddress(), config.getMaxClientCnxns(), config.getClientPortListenBacklog(), false);
                   // 使用 ServerCnxnFactory 启动 zookeeperServer
                   cnxnFactory.startup(zkServer);
                   // zkServer has been started. So we don't need to start it again in secureCnxnFactory.
                   // 因为在此处 zkServer 已经启动，所以我们不需要在 secureCnxnFactory 中再次启动它
                   needStartZKServer = false;
               }
               // 8.创建并启动secureCnxnFactory
               if (config.getSecureClientPortAddress() != null) {
                   secureCnxnFactory = ServerCnxnFactory.createFactory();
                   secureCnxnFactory.configure(config.getSecureClientPortAddress(), config.getMaxClientCnxns(), config.getClientPortListenBacklog(), true);
                   secureCnxnFactory.startup(zkServer, needStartZKServer);
               }
   
               // 9.创建并启动ContainerManager
               containerManager = new ContainerManager(
                   zkServer.getZKDatabase(),
                   zkServer.firstProcessor,
                   Integer.getInteger("znode.container.checkIntervalMs", (int) TimeUnit.MINUTES.toMillis(1)),
                   Integer.getInteger("znode.container.maxPerMinute", 10000),
                   Long.getLong("znode.container.maxNeverUsedIntervalMs", 0)
               );
               containerManager.start();
               ZKAuditProvider.addZKStartStopAuditLog();
   
               serverStarted();
   
               // Watch status of ZooKeeper server. It will do a graceful shutdown
               // if the server is not running or hits an internal error.
               // 服务器正常启动时,运行到此处阻塞,只有server的state变为ERROR或SHUTDOWN时继续运行后面的代码
               shutdownLatch.await();
   
               shutdown();
   
               if (cnxnFactory != null) {
                   cnxnFactory.join();
               }
               if (secureCnxnFactory != null) {
                   secureCnxnFactory.join();
               }
               if (zkServer.canShutdown()) {
                   zkServer.shutdown(true);
               }
           } catch (InterruptedException e) {
               // warn, but generally this is ok
               LOG.warn("Server interrupted", e);
           } finally {
               if (txnLog != null) {
                   txnLog.close();
               }
               if (metricsProvider != null) {
                   try {
                       metricsProvider.stop();
                   } catch (Throwable error) {
                       LOG.warn("Error while stopping metrics", error);
                   }
               }
           }
       }
   ```

4. ServerCnxnFactory（有两个实现模式NIOServerCnxnFactory、NettyServerCnxnFactory）以NettyServerCnxnFactory代码分析
   ```java
   // org.apache.zookeeper.server.ServerCnxnFactory#createFactory()
   public static ServerCnxnFactory createFactory() throws IOException {
           // 从配置文件中获取将要创建的 ServerCnxnFactory 类型
           String serverCnxnFactoryName = System.getProperty(ZOOKEEPER_SERVER_CNXN_FACTORY);
           if (serverCnxnFactoryName == null) {
               // 如果系统配置文件中未设置该属性则默认使用 JDK 的 NIO 实现版本 NIOServerCnxnFactory
               serverCnxnFactoryName = NIOServerCnxnFactory.class.getName();
           }
           try {
               // 通过反射调用构造方法实例化 ServerCnxnFactory 对象
               ServerCnxnFactory serverCnxnFactory = (ServerCnxnFactory) Class.forName(serverCnxnFactoryName)
                                                                              .getDeclaredConstructor()
                                                                              .newInstance();
               LOG.info("Using {} as server connection factory", serverCnxnFactoryName);
               return serverCnxnFactory;
           } catch (Exception e) {
               IOException ioe = new IOException("Couldn't instantiate " + serverCnxnFactoryName, e);
               throw ioe;
           }
       }
   
   // org.apache.zookeeper.server.ServerCnxnFactory#startup(org.apache.zookeeper.server.ZooKeeperServer)
   public void startup(ZooKeeperServer zkServer) throws IOException, InterruptedException {
           // 启动 zkServer
           startup(zkServer, true);
       }
   
   // org.apache.zookeeper.server.NettyServerCnxnFactory#startup
   public void startup(ZooKeeperServer zks, boolean startServer) throws IOException, InterruptedException {
           // 绑定 Netty 监听端口
           start();
           // 完成 zkServer 和 ServerCnxnFactory 的双向绑定
           setZooKeeperServer(zks);
           if (startServer) {
               // 启动 zkServer
               zks.startdata();
               zks.startup();
           }
       }
   
   // org.apache.zookeeper.server.NettyServerCnxnFactory#start
   public void start() {
           if (listenBacklog != -1) {
               // 设置半连队列大小
               bootstrap.option(ChannelOption.SO_BACKLOG, listenBacklog);
           }
           LOG.info("binding to port {}", localAddress);
           // 绑定端口
           parentChannel = bootstrap.bind(localAddress).syncUninterruptibly().channel();
           // Port changes after bind() if the original port was 0, update
           // localAddress to get the real port.
           localAddress = (InetSocketAddress) parentChannel.localAddress();
           LOG.info("bound to port {}", getLocalPort());
       }
   
   // org.apache.zookeeper.server.ServerCnxnFactory#setZooKeeperServer
   public final void setZooKeeperServer(ZooKeeperServer zks) {
           // zkServer 和 ServerCnxnFactory 的双向绑定
           this.zkServer = zks;
           if (zks != null) {
               if (secure) {
                   zks.setSecureServerCnxnFactory(this);
               } else {
                   zks.setServerCnxnFactory(this);
               }
           }
       }
   ```

5. 配置 Netty

   ```java
   NettyServerCnxnFactory() {
           x509Util = new ClientX509Util();
   
           boolean usePortUnification = Boolean.getBoolean(PORT_UNIFICATION_KEY);
           LOG.info("{}={}", PORT_UNIFICATION_KEY, usePortUnification);
           if (usePortUnification) {
               try {
                   QuorumPeerConfig.configureSSLAuth();
               } catch (QuorumPeerConfig.ConfigException e) {
                   LOG.error("unable to set up SslAuthProvider, turning off client port unification", e);
                   usePortUnification = false;
               }
           }
           this.shouldUsePortUnification = usePortUnification;
   
           this.advancedFlowControlEnabled = Boolean.getBoolean(NETTY_ADVANCED_FLOW_CONTROL);
           LOG.info("{} = {}", NETTY_ADVANCED_FLOW_CONTROL, this.advancedFlowControlEnabled);
   
           setOutstandingHandshakeLimit(Integer.getInteger(OUTSTANDING_HANDSHAKE_LIMIT, -1));
           // bossGroup处理客户端的连接请求，workerGroup负责每个连接IO事件的处理，典型的reactor模式
           EventLoopGroup bossGroup = NettyUtils.newNioOrEpollEventLoopGroup(NettyUtils.getClientReachableLocalInetAddressCount());
           // 创建 workerGroup 且优先选择使用更高性能的 EpollEventLoopGroup
           EventLoopGroup workerGroup = NettyUtils.newNioOrEpollEventLoopGroup();
           // 创建ServerBootstrap 配置 handler
           ServerBootstrap bootstrap = new ServerBootstrap().group(bossGroup, workerGroup)
                                                            .channel(NettyUtils.nioOrEpollServerSocketChannel())
                                                            // parent channel options
                                                            .option(ChannelOption.SO_REUSEADDR, true)
                                                            // child channels options
                                                            .childOption(ChannelOption.TCP_NODELAY, true)
                                                            .childOption(ChannelOption.SO_LINGER, -1)
                                                            .childHandler(new ChannelInitializer<SocketChannel>() {
                                                                @Override
                                                                protected void initChannel(SocketChannel ch) throws Exception {
                                                                    ChannelPipeline pipeline = ch.pipeline();
                                                                    if (advancedFlowControlEnabled) {
                                                                        pipeline.addLast(readIssuedTrackingHandler);
                                                                    }
                                                                    if (secure) {
                                                                        initSSL(pipeline, false);
                                                                    } else if (shouldUsePortUnification) {
                                                                        initSSL(pipeline, true);
                                                                    }
                                                                    // 向 pipeline 添加 channelHandler 处理器
                                                                    pipeline.addLast("servercnxnfactory", channelHandler);
                                                                }
                                                            });
           this.bootstrap = configureBootstrapAllocator(bootstrap);
           this.bootstrap.validate();
       }
   ```

6. ZooKeeperServer

   ```java
   // org.apache.zookeeper.server.ZooKeeperServer#startup
   public synchronized void startup() {
           // 启动zkServer 并设置为 RUNNING 状态
           startupWithServerState(State.RUNNING);
       }
   
   // org.apache.zookeeper.server.ZooKeeperServer#startupWithServerState
   private void startupWithServerState(State state) {
           // session 管理
           if (sessionTracker == null) {
               createSessionTracker();
           }
           startSessionTracker();
           // 请求前置处理器，是一个生产消费队列，对每个请求状态码进行判断，分别进行请求前置处理
           setupRequestProcessors();
   
           startRequestThrottler();
   
           // 注册jmx bean
           registerJMX();
   
           // jvm停止监控，默认不开启
           startJvmPauseMonitor();
   
           // 通过zxdb和zkserver填写相关指标
           registerMetrics();
   
           setState(state);
   
           requestPathMetricsCollector.start();
   
           localSessionEnabled = sessionTracker.isLocalSessionsEnabled();
   
           notifyAll();
       }
   
   
   ```

7. CnxnChannelHandler

   ```java
   // org.apache.zookeeper.server.NettyServerCnxnFactory.CnxnChannelHandler
   class CnxnChannelHandler extends ChannelDuplexHandler {
   
           // 当服务端接受客户端的socket连接之后，channelActive会被调用
           // 正常情况下通过channelActive服务端session层的连接表示对象会被建立起来
           @Override
           public void channelActive(ChannelHandlerContext ctx) throws Exception {
               if (LOG.isTraceEnabled()) {
                   LOG.trace("Channel active {}", ctx.channel());
               }
   
               final Channel channel = ctx.channel();
               // 连接数有没有达到服务端设置的连接最大数，如果达到了，直接关闭底层socket，拒绝新的连接请求
               if (limitTotalNumberOfCnxns()) {
                   ServerMetrics.getMetrics().CONNECTION_REJECTED.add(1);
                   channel.close();
                   return;
               }
               InetAddress addr = ((InetSocketAddress) channel.remoteAddress()).getAddress();
               // 单个客户端的连接数是不是超过了用户设置的最大可建立连接数，如果达到了拒绝客户端的连接请求
               if (maxClientCnxns > 0 && getClientCnxnCount(addr) >= maxClientCnxns) {
                   ServerMetrics.getMetrics().CONNECTION_REJECTED.add(1);
                   LOG.warn("Too many connections from {} - max is {}", addr, maxClientCnxns);
                   channel.close();
                   return;
               }
   
               // 创建session会话层的连接表示对象NettyServerCnxn
               NettyServerCnxn cnxn = new NettyServerCnxn(channel, zkServer, NettyServerCnxnFactory.this);
               // 将 NettyServerCnxn 保存至 Channel 属性中（接收请求时会用到）
               ctx.channel().attr(CONNECTION_ATTRIBUTE).set(cnxn);
   
               // Check the zkServer assigned to the cnxn is still running,
               // close it before starting the heavy TLS handshake
               if (!cnxn.isZKServerRunning()) {
                   LOG.warn("Zookeeper server is not running, close the connection before starting the TLS handshake");
                   ServerMetrics.getMetrics().CNXN_CLOSED_WITHOUT_ZK_SERVER_RUNNING.add(1);
                   channel.close();
                   return;
               }
   
               if (handshakeThrottlingEnabled) {
                   // Favor to check and throttling even in dual mode which
                   // accepts both secure and insecure connections, since
                   // it's more efficient than throttling when we know it's
                   // a secure connection in DualModeSslHandler.
                   //
                   // From benchmark, this reduced around 15% reconnect time.
                   int outstandingHandshakesNum = outstandingHandshake.addAndGet(1);
                   if (outstandingHandshakesNum > outstandingHandshakeLimit) {
                       outstandingHandshake.addAndGet(-1);
                       channel.close();
                       ServerMetrics.getMetrics().TLS_HANDSHAKE_EXCEEDED.add(1);
                   } else {
                       cnxn.setHandshakeState(HandshakeState.STARTED);
                   }
               }
   
               if (secure) {
                   SslHandler sslHandler = ctx.pipeline().get(SslHandler.class);
                   Future<Channel> handshakeFuture = sslHandler.handshakeFuture();
                   handshakeFuture.addListener(new CertificateVerifier(sslHandler, cnxn));
               } else if (!shouldUsePortUnification) {
                   // 将 Channel 和 NettyServerCnxn 分别添加到集合中保存
                   allChannels.add(ctx.channel());
                   addCnxn(cnxn);
               }
               if (ctx.channel().pipeline().get(SslHandler.class) == null) {
                   SocketAddress remoteAddress = cnxn.getChannel().remoteAddress();
                   if (remoteAddress != null
                           && !((InetSocketAddress) remoteAddress).getAddress().isLoopbackAddress()) {
                       LOG.trace("NettyChannelHandler channelActive: remote={} local={}", remoteAddress, cnxn.getChannel().localAddress());
                       zkServer.serverStats().incrementNonMTLSRemoteConnCount();
                   } else {
                       zkServer.serverStats().incrementNonMTLSLocalConnCount();
                   }
               }
           }
   
           // 连接关闭时的处理逻辑
           @Override
           public void channelInactive(ChannelHandlerContext ctx) throws Exception {
               if (LOG.isTraceEnabled()) {
                   LOG.trace("Channel inactive {}", ctx.channel());
               }
   
               // 将 Channel 从 allChannels 集合中移除
               allChannels.remove(ctx.channel());
               NettyServerCnxn cnxn = ctx.channel().attr(CONNECTION_ATTRIBUTE).getAndSet(null);
               if (cnxn != null) {
                   if (LOG.isTraceEnabled()) {
                       LOG.trace("Channel inactive caused close {}", cnxn);
                   }
                   updateHandshakeCountIfStarted(cnxn);
                   // 关闭 NettyServerCnxn
                   cnxn.close(ServerCnxn.DisconnectReason.CHANNEL_DISCONNECTED);
               }
           }
   
           // 异常处理方法
           @Override
           public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) throws Exception {
               LOG.warn("Exception caught", cause);
               NettyServerCnxn cnxn = ctx.channel().attr(CONNECTION_ATTRIBUTE).getAndSet(null);
               if (cnxn != null) {
                   LOG.debug("Closing {}", cnxn);
                   updateHandshakeCountIfStarted(cnxn);
                   cnxn.close(ServerCnxn.DisconnectReason.CHANNEL_CLOSED_EXCEPTION);
               }
           }
   
           // 处理用自定义的channel事件：主要是处理channel读和不读的事件
           @Override
           public void userEventTriggered(ChannelHandlerContext ctx, Object evt) throws Exception {
               try {
                   if (evt == NettyServerCnxn.ReadEvent.ENABLE) {
                       LOG.debug("Received ReadEvent.ENABLE");
                       NettyServerCnxn cnxn = ctx.channel().attr(CONNECTION_ATTRIBUTE).get();
                       // TODO: Not sure if cnxn can be null here. It becomes null if channelInactive()
                       // or exceptionCaught() trigger, but it's unclear to me if userEventTriggered() can run
                       // after either of those. Check for null just to be safe ...
                       if (cnxn != null) {
                           if (cnxn.getQueuedReadableBytes() > 0) {
                               cnxn.processQueuedBuffer();
                               if (advancedFlowControlEnabled && cnxn.getQueuedReadableBytes() == 0) {
                                   // trigger a read if we have consumed all
                                   // backlog
                                   ctx.read();
                                   LOG.debug("Issued a read after queuedBuffer drained");
                               }
                           }
                       }
                       if (!advancedFlowControlEnabled) {
                           ctx.channel().config().setAutoRead(true);
                       }
                   } else if (evt == NettyServerCnxn.ReadEvent.DISABLE) {
                       LOG.debug("Received ReadEvent.DISABLE");
                       ctx.channel().config().setAutoRead(false);
                   }
               } finally {
                   ReferenceCountUtil.release(evt);
               }
           }
   
           // 服务端读取客户端发送来的请求数据
           @Override
           public void channelRead(ChannelHandlerContext ctx, Object msg) throws Exception {
               try {
                   if (LOG.isTraceEnabled()) {
                       LOG.trace("message received called {}", msg);
                   }
                   try {
                       LOG.debug("New message {} from {}", msg, ctx.channel());
                       // channelActive时候 将NettyServerCnxn注册到的Channel 属性中
                       NettyServerCnxn cnxn = ctx.channel().attr(CONNECTION_ATTRIBUTE).get();
                       if (cnxn == null) {
                           LOG.error("channelRead() on a closed or closing NettyServerCnxn");
                       } else {
                           // 如果 NettyServerCnxn 未被关闭或未被正在关闭则调用 processMessage 处理请求
                           cnxn.processMessage((ByteBuf) msg);
                       }
                   } catch (Exception ex) {
                       LOG.error("Unexpected exception in receive", ex);
                       throw ex;
                   }
               } finally {
                   // 释放 Buffer
                   ReferenceCountUtil.release(msg);
               }
           }
   
           @Override
           public void channelReadComplete(ChannelHandlerContext ctx) throws Exception {
               if (advancedFlowControlEnabled) {
                   NettyServerCnxn cnxn = ctx.channel().attr(CONNECTION_ATTRIBUTE).get();
                   if (cnxn != null && cnxn.getQueuedReadableBytes() == 0 && cnxn.readIssuedAfterReadComplete == 0) {
                       ctx.read();
                       LOG.debug("Issued a read since we do not have anything to consume after channelReadComplete");
                   }
               }
   
               ctx.fireChannelReadComplete();
           }
   
           // Use a single listener instance to reduce GC
           // Note: this listener is only added when LOG.isTraceEnabled() is true,
           // so it should not do any work other than trace logging.
           private final GenericFutureListener<Future<Void>> onWriteCompletedTracer = (f) -> {
               if (LOG.isTraceEnabled()) {
                   LOG.trace("write success: {}", f.isSuccess());
               }
           };
   
           @Override
           public void write(ChannelHandlerContext ctx, Object msg, ChannelPromise promise) throws Exception {
               if (LOG.isTraceEnabled()) {
                   promise.addListener(onWriteCompletedTracer);
               }
               super.write(ctx, msg, promise);
           }
   
       }
   ```

8. 接收并处理请求 NettyServerCnxn

   ```java
   // org.apache.zookeeper.server.NettyServerCnxn#processMessage
   void processMessage(ByteBuf buf) {
           checkIsInEventLoop("processMessage");
           LOG.debug("0x{} queuedBuffer: {}", Long.toHexString(sessionId), queuedBuffer);
   
           if (LOG.isTraceEnabled()) {
               LOG.trace("0x{} buf {}", Long.toHexString(sessionId), ByteBufUtil.hexDump(buf));
           }
   
           if (throttled.get()) {
               LOG.debug("Received message while throttled");
               // we are throttled, so we need to queue
               // 如果当前为限流状态则直接进行排队
               if (queuedBuffer == null) {
                   LOG.debug("allocating queue");
                   queuedBuffer = channel.alloc().compositeBuffer();
               }
               // 添加至 queuedBuffer 中排队
               appendToQueuedBuffer(buf.retainedDuplicate());
               if (LOG.isTraceEnabled()) {
                   LOG.trace("0x{} queuedBuffer {}", Long.toHexString(sessionId), ByteBufUtil.hexDump(queuedBuffer));
               }
           } else {
               LOG.debug("not throttled");
               if (queuedBuffer != null) {
                   // 排队队列不为空 直接加入对接排队
                   appendToQueuedBuffer(buf.retainedDuplicate());
                   // 该方法中包含对于 Channel 正在关闭时的处理逻辑，但对于响应的处理实质还是调用 receiveMessage 方法
                   processQueuedBuffer();
               } else {
                   // 调用 receiveMessage 处理响应
                   receiveMessage(buf);
                   // Have to check !closingChannel, because an error in
                   // receiveMessage() could have led to close() being called.
                   // 必须再次检查通道是否正在关闭，因为在 receiveMessage 方法中可能出现错误而导致 close() 被调用  
                   if (!closingChannel && buf.isReadable()) {
                       if (LOG.isTraceEnabled()) {
                           LOG.trace("Before copy {}", buf);
                       }
   
                       if (queuedBuffer == null) {
                           queuedBuffer = channel.alloc().compositeBuffer();
                       }
                       appendToQueuedBuffer(buf.retainedSlice(buf.readerIndex(), buf.readableBytes()));
                       if (LOG.isTraceEnabled()) {
                           LOG.trace("Copy is {}", queuedBuffer);
                           LOG.trace("0x{} queuedBuffer {}", Long.toHexString(sessionId), ByteBufUtil.hexDump(queuedBuffer));
                       }
                   }
               }
           }
       }
   ```
   
    **Netty.CompositeByteBuf** ：复合缓冲区是多个ByteBuf组合的视图，复合缓冲区就像一个列表，我们可以动态的添加和删除其中的 ByteBuf，可以组合多个 Buffer 对象合并成一个逻辑上的对象，避免通过传统内存拷贝的方式将几个 Buffer 合并成一个大的 Buffer
   
   ```java
   // org.apache.zookeeper.server.NettyServerCnxn#receiveMessage
   private void receiveMessage(ByteBuf message) {
           checkIsInEventLoop("receiveMessage");
           try {
               // 当writerIndex大于readerIndex(表示ByteBuf中还有可读内容)
               // 且throttled为false时执行while循环体
               while (message.isReadable() && !throttled.get()) {
                   // bb不为null，表示已经准备好读取message
                   if (bb != null) {
                       // 其中主要的部分是判断bb的剩余空间是否大于message中的内容，
                       // 就是判断bb是否还有足够空间存储message内容，
                       // 然后设置bb的limit，之后将message内容读入bb缓冲中，
                       // 之后再次确定时候已经读完message内容，统计接收信息，
                       // 再根据是否已经初始化来处理包或者是连接请求，其中的请求内容都存储在bb中
                       if (LOG.isTraceEnabled()) {
                           LOG.trace("message readable {} bb len {} {}", message.readableBytes(), bb.remaining(), bb);
                           ByteBuffer dat = bb.duplicate();
                           dat.flip();
                           LOG.trace("0x{} bb {}", Long.toHexString(sessionId), ByteBufUtil.hexDump(Unpooled.wrappedBuffer(dat)));
                       }
   
                       // bb剩余空间大于message中可读字节大小
                       if (bb.remaining() > message.readableBytes()) {
                           // 确定新的limit
                           int newLimit = bb.position() + message.readableBytes();
                           bb.limit(newLimit);
                       }
                       // 将message写入bb中
                       message.readBytes(bb);
                       // 重置bb的limit
                       bb.limit(bb.capacity());
   
                       if (LOG.isTraceEnabled()) {
                           LOG.trace("after readBytes message readable {} bb len {} {}", message.readableBytes(), bb.remaining(), bb);
                           ByteBuffer dat = bb.duplicate();
                           dat.flip();
                           LOG.trace("after readbytes 0x{} bb {}",
                                     Long.toHexString(sessionId),
                                     ByteBufUtil.hexDump(Unpooled.wrappedBuffer(dat)));
                       }
                       // 已经读完message，表示内容已经全部接收
                       if (bb.remaining() == 0) {
                           // 翻转，可读
                           bb.flip();
                           // 统计接收信息
                           packetReceived(4 + bb.remaining());
   
                           ZooKeeperServer zks = this.zkServer;
                           // Zookeeper服务器为空 抛出异常
                           if (zks == null || !zks.isRunning()) {
                               throw new IOException("ZK down");
                           }
                           // 未被初始化
                           if (initialized) {
                               // TODO: if zks.processPacket() is changed to take a ByteBuffer[],
                               // we could implement zero-copy queueing.
                               // 处理bb中包含的包信息
                               zks.processPacket(this, bb);
                           } else {
                               // 已经初始化
                               LOG.debug("got conn req request from {}", getRemoteSocketAddress());
                               // 处理连接请求
                               zks.processConnectRequest(this, bb);
                               initialized = true;
                           }
                           bb = null;
                       }
                   } else {
                       if (LOG.isTraceEnabled()) {
                           LOG.trace("message readable {} bblenrem {}", message.readableBytes(), bbLen.remaining());
                           ByteBuffer dat = bbLen.duplicate();
                           dat.flip();
                           LOG.trace("0x{} bbLen {}", Long.toHexString(sessionId), ByteBufUtil.hexDump(Unpooled.wrappedBuffer(dat)));
                       }
   
                       if (message.readableBytes() < bbLen.remaining()) {
                           bbLen.limit(bbLen.position() + message.readableBytes());
                       }
                       // 4 byte 的 ByteBuffer 用于读取数据包中前 4 byte 所记录的数据包中实际数据长度
                       message.readBytes(bbLen);
                       bbLen.limit(bbLen.capacity());
                       if (bbLen.remaining() == 0) {
                           bbLen.flip();
   
                           if (LOG.isTraceEnabled()) {
                               LOG.trace("0x{} bbLen {}", Long.toHexString(sessionId), ByteBufUtil.hexDump(Unpooled.wrappedBuffer(bbLen)));
                           }
                           // 读取前 4 byte 所代表的的 Int 数值
                           int len = bbLen.getInt();
                           if (LOG.isTraceEnabled()) {
                               LOG.trace("0x{} bbLen len is {}", Long.toHexString(sessionId), len);
                           }
   
                           bbLen.clear();
                           if (!initialized) {
                               if (checkFourLetterWord(channel, message, len)) {
                                   return;
                               }
                           }
                           if (len < 0 || len > BinaryInputArchive.maxBuffer) {
                               throw new IOException("Len error " + len);
                           }
                           ZooKeeperServer zks = this.zkServer;
                           if (zks == null || !zks.isRunning()) {
                               throw new IOException("ZK down");
                           }
                           // checkRequestSize will throw IOException if request is rejected
                           zks.checkRequestSizeWhenReceivingMessage(len);
                           // 将 bb 赋值为数据包中前 4 byte Int 值长度的 ByteBuffer
                           bb = ByteBuffer.allocate(len);
                       }
                   }
               }
           } catch (IOException e) {
               LOG.warn("Closing connection to {}", getRemoteSocketAddress(), e);
               close(DisconnectReason.IO_EXCEPTION);
           } catch (ClientCnxnLimitException e) {
               // Common case exception, print at debug level
               ServerMetrics.getMetrics().CONNECTION_REJECTED.add(1);
   
               LOG.debug("Closing connection to {}", getRemoteSocketAddress(), e);
               close(DisconnectReason.CLIENT_RATE_LIMIT);
           }
       }
   ```
   
   **receiveMessage**逻辑梳理
   
   1. 当数据包首次进入该方法时 bb 为空，所以直接进入第二个语句块；
   2. 在第二个语句块中会从数据包中读入长度为 4 byte 的 ByteBuffer（ bblen = ByteBuffer.allocate(4) ），然后将其转换为一个 Int 整型值 len ；
   3. 根据整型值 len 申请长度为 len 的 ByteBuffer 赋值给 bb ，然后结束此轮循环；
   4. 进入第二轮循环时 bb 已经是长度为 len 的 ByteBuffer（ len 为数据包中有效数据的长度 ），所以进入第一个语句块；
   5. 在第一个语句块中会直接从传入的数据包中读长度为 len 的数据并写入到 bb 中（一次性完整的将全部有效数据读入）；
   6. 最后将获取到的有效数据传入 processPacket 方法中进行处理；
   
   ```java
   // org.apache.zookeeper.server.ZooKeeperServer#processPacket
   public void processPacket(ServerCnxn cnxn, ByteBuffer incomingBuffer) throws IOException {
   	// We have the request, now process and setup for next
       InputStream bais = new ByteBufferInputStream(incomingBuffer);
       BinaryInputArchive bia = BinaryInputArchive.getArchive(bais);
       // 解析请求头至临时变量 h
       RequestHeader h = new RequestHeader();
       h.deserialize(bia, "header");
       // 从原缓冲区的当前位置开始创建一个新的字节缓冲区
   	incomingBuffer = incomingBuffer.slice();
   	if (h.getType() == OpCode.auth) {
   		AuthPacket authPacket = new AuthPacket();
           ByteBufferInputStream.byteBuffer2Record(incomingBuffer, authPacket);
               
           // 省略认证等代码...
           else {
           	// 将数据包中的有效数据组装为 Request 请求
               Request si = new Request(cnxn, cnxn.getSessionId(), h.getXid(), h.getType(), incomingBuffer, cnxn.getAuthInfo());
               si.setOwner(ServerCnxn.me);
               // 将组装好的 Request 请求通过 submitRequest 方法发送给上层逻辑处理
               submitRequest(si);
           }
       }
       cnxn.incrOutstandingRequests(h);
   }
   
   ```
   
   ```java
   public void submitRequest(Request si) {
           enqueueRequest(si);
       }
   
   public void enqueueRequest(Request si) {
           if (requestThrottler == null) {
               synchronized (this) {
                   try {
                       // Since all requests are passed to the request
                       // processor it should wait for setting up the request
                       // processor chain. The state will be updated to RUNNING
                       // after the setup.
                       while (state == State.INITIAL) {
                           wait(1000);
                       }
                   } catch (InterruptedException e) {
                       LOG.warn("Unexpected interruption", e);
                   }
                   if (requestThrottler == null) {
                       throw new RuntimeException("Not started");
                   }
               }
           }
           // 提交请求给限流器
           requestThrottler.submitRequest(si);
       }
   
   public void submitRequest(Request request) {
           // 如果已停止，则删除队列
           if (stopping) {
               LOG.debug("Shutdown in progress. Request cannot be processed");
               dropRequest(request);
           } else {
               request.requestThrottleQueueTime = Time.currentElapsedTime();
               // LinkedBlockingQueue 入队，最终由该线程去异步处理
               submittedRequests.add(request);
           }
       }
   ```
   
   通过上面的tcp数据转换，将其转换为了 Request 实例，提交到队列了。接下来这个队列将被 RequestThrottler 处理，它的作用是判定是否超出了设置的最大请求数，如果超出，则作等待处理，防止下游无法应对
   
   ```java
   org.apache.zookeeper.server.RequestThrottler#run
   @Override
       public void run() {
           try {
               while (true) {
                   if (killed) {
                       break;
                   }
   
                   // 阻塞式获取，即只要数据被提交，就会被立即处理
                   Request request = submittedRequests.take();
                   if (Request.requestOfDeath == request) {
                       break;
                   }
   
                   if (request.mustDrop()) {
                       continue;
                   }
   
                   // Throttling is disabled when maxRequests = 0
                   // maxRequests等于0 不开启限流控制
                   if (maxRequests > 0) {
                       while (!killed) {
                           if (dropStaleRequests && request.isStale()) {
                               // Note: this will close the connection
                               dropRequest(request);
                               ServerMetrics.getMetrics().STALE_REQUESTS_DROPPED.add(1);
                               request = null;
                               break;
                           }
                           // 只要没达到最大限制，直接通过
                           if (zks.getInProcess() < maxRequests) {
                               break;
                           }
                           throttleSleep(stallTime);
                       }
                   }
   
                   if (killed) {
                       break;
                   }
   
                   // A dropped stale request will be null
                   if (request != null) {
                       if (request.isStale()) {
                           ServerMetrics.getMetrics().STALE_REQUESTS.add(1);
                       }
                       final long elapsedTime = Time.currentElapsedTime() - request.requestThrottleQueueTime;
                       ServerMetrics.getMetrics().REQUEST_THROTTLE_QUEUE_TIME.add(elapsedTime);
                       if (shouldThrottleOp(request, elapsedTime)) {
                         request.setIsThrottled(true);
                         ServerMetrics.getMetrics().THROTTLED_OPS.add(1);
                       }
                       // 验证通过后，提交给 zkServer 处理
                       zks.submitRequestNow(request);
                   }
               }
           } catch (InterruptedException e) {
               LOG.error("Unexpected interruption", e);
           }
           int dropped = drainQueue();
           LOG.info("RequestThrottler shutdown. Dropped {} requests", dropped);
       }
   
   // org.apache.zookeeper.server.ZooKeeperServer#submitRequestNow
   public void submitRequestNow(Request si) {
           // 确保处理器链已生成
           if (firstProcessor == null) {
               synchronized (this) {
                   try {
                       // Since all requests are passed to the request
                       // processor it should wait for setting up the request
                       // processor chain. The state will be updated to RUNNING
                       // after the setup.
                       // 因为所有的请求都被传递给请求处理器，所以应该等待请求处理器链建立完成
                       // 且当请求处理器链建立完成后，状态将更新为 RUNNING
                       while (state == State.INITIAL) {
                           wait(1000);
                       }
                   } catch (InterruptedException e) {
                       LOG.warn("Unexpected interruption", e);
                   }
                   if (firstProcessor == null || state != State.RUNNING) {
                       throw new RuntimeException("Not started");
                   }
               }
           }
           try {
               // 验证 sessionId
               touch(si.cnxn);
               // 验证 Request 是否有效
               boolean validpacket = Request.isValid(si.type);
               if (validpacket) {
                   setLocalSessionFlag(si);
                   // 如果 Request 有效则将其传递给请求处理链（Request Processor Pipeline）的第一个请求处理器
                   firstProcessor.processRequest(si);
                   if (si.cnxn != null) {
                       incInProcess();
                   }
               } else {
                   LOG.warn("Received packet at server of unknown type {}", si.type);
                   // Update request accounting/throttling limits
                   requestFinished(si);
                   // 该请求来自未知类型的客户端
                   new UnimplementedRequestProcessor().processRequest(si);
               }
           } catch (MissingSessionException e) {
               LOG.debug("Dropping request.", e);
               // Update request accounting/throttling limits
               requestFinished(si);
           } catch (RequestProcessorException e) {
               LOG.error("Unable to process request", e);
               // Update request accounting/throttling limits
               requestFinished(si);
           }
       }
   ```
   
9. 发送Response

   因为Zookeeper 中对于请求的处理是采用 Request Processor Pipeline 来完成的，所以对于处理请求后组装并发送响应的工作就是由最后一个 FinalRequestProcessor 来完成的，因此我们下面的源码分析就从 FinalRequestProcessor 的 processRequest 方法开始，该方法的入参为上一个 Request Processor 处理后的 Request 请求

   ```java
   // org.apache.zookeeper.server.FinalRequestProcessor#processRequest
   public void processRequest(Request request) {
   	// 因为重点分析发送响应流程，所以省略居多分类别处理请求并生成 hdr 响应头 和 rsp 响应体代码...
   	try {
   		// 在上面处理过 Request 请求后将生成的响应头和响应体作为入参调用 sendResponse 方法发送响应
   		cnxn.sendResponse(hdr, rsp, "response");
   		// 如果 Request 的类型为 closeSession 则进入关闭逻辑
   		if (request.type == OpCode.closeSession) {
   			cnxn.sendCloseSession();
   		}
   	}
   }
   ```

   ```java
   @Override
   public int sendResponse(ReplyHeader h, Record r, String tag,
                           String cacheKey, Stat stat, int opCode) throws IOException {
     // cacheKey and stat are used in caching, which is not
     // implemented here. Implementation example can be found in NIOServerCnxn.
     if (closingChannel || !channel.isOpen()) {
       return 0;
     }
     // 序列化数据
     ByteBuffer[] bb = serialize(h, r, tag, cacheKey, stat, opCode);
     int responseSize = bb[0].getInt();
     bb[0].rewind();
     // 发送数据
     sendBuffer(bb);
     decrOutstandingAndCheckThrottle(h);
     return responseSize;
   }
   ```

   ```java
   @Override
   public void sendBuffer(ByteBuffer... buffers) {
     // 如果 ByteBuffer 为 closeConn 则调用 close() 进入关闭逻辑
     if (buffers.length == 1 && buffers[0] == ServerCnxnFactory.closeConn) {
       close(DisconnectReason.CLIENT_CLOSED_CONNECTION);
       return;
     }
     // 将 ByteBuffer 中的数据写入 Channel 并通过 flush 将其发送    
     channel.writeAndFlush(Unpooled.wrappedBuffer(buffers)).addListener(onSendBufferDoneListener);
   }
   ```

## 源码总结

### 接收请求

1. 服务端从 Netty Channel 的 channelRead 方法接收请求，并通过 NettyServerCnxn 的 processMessage 方法将其转发给当前 Channel 所绑定的 NettyServerCnxn ；
2. 在 NettyServerCnxn 的 processMessage 方法中会进行限流（throttle）处理将请求 Buffer 拷贝到 queuedBuffer 中，然后调用 receiveMessage 方法对请求做进一步处理；
3. receiveMessage 方法的主要工作就是从传入的 ByteBuf 中读取有效的数据（数据包前 4 byte 记录有效数据的长度），并将其转化为 ByteBuffer 传给 ZooKeeperServer 的 processPacket 进行处理；
4. 在 processPacket 方法中会从 ByteBuffer 中解析出请求头和请求体，并将其封装为 Request 后传给上层的 submitRequest 方法进行处理；
5. submitRequest 会等待第一个 Request Processor 初始化完成后进行请求的验证工作，然后将验证成功的请求传递给 Request Processor Pipeline 中的第一个 Request Processor 进行处理；

### 发送响应

1. 响应的发送工作是由 Request Processor Pipeline 的最后一个 Request Processor 来完成的，在 FinalRequestProcessor 的 processRequest 方法中会根据请求的类型对传入的请求进行处理，并生成响应头和响应体传给 ServerCnxn 的 sendResponse 方法；
2. 在 sendResponse 方法中会将入参的响应头和响应体组装为一个完整的响应，并将其转换为 ByteBuffer 通过 NettyServerCnxn 的 sendBuffer 方法传给 NettyServerCnxn ；
3. 在 NettyServerCnxn 的 sendBuffer 方法中会进行 ByteBuffer 类型的判断，如果类型为 closeConn 则进入关闭逻辑，否则通过 Channel 的 writeAndFlush 方法将响应发送；

