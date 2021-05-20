---
title: MySQL -- 基础架构
date: 2020-01-01
categories:
    - Storage
    - MySQL
tags:
    - Storage
    - MySQL
typora-root-url: ../../source

---

## 查询语句

```sql
mysql> select * from T where ID=10;
```

## 基本架构

<img src="/images/mysql-基础架构/mysql-architecture-20210517110625157.png" alt="img" style="zoom:28%;" />



1. 大体上，MySQL可以分为**Server层**和**存储引擎层**
2. Server层包括**连接器、查询缓存、分析器、优化器和执行器**等
   - 涵盖MySQL的**大多数核心服务功能**，以及**所有的内置函数**
   - 所有的**跨存储引擎的功能**都在这一层实现，例如存储过程、触发器和视图等
3. 存储引擎层负责**数据的存储和提取**，架构模式为**插件式**
   - 支持InnoDB、MyISAM和Memory等存储引擎
   - 最常用为**InnoDB**（Since 5.5.5，默认）

### 连接器

连接器负责跟客户端**建立连接、获取权限、维持和管理连接**。命令如下：

```
mysql -h$host -P$port -u$user -p
```

### 权限

- 连接命令中的 mysql 是客户端工具，用来跟服务端建立连接
- 在完成经典的 TCP 握手后，连接器就要开始认证你的身份，使用 `-u`  `-p`
  - 如果用户名或密码不对，你就会收到一个**"Access denied for user"**的错误，然后客户端程序结束执行
  - 如果用户名密码认证通过，连接器会到**权限表**里面查出你拥有的权限
    - 之后，这个连接里面的权限判断逻辑，都将依赖于此时读到的权限
    - 因此即使用管理员账号对权限进行修改，也**不会影响到已经存在连接的权限**

### 连接

- 连接完成后，如果你没有后续的动作，这个连接就处于空闲状态
  - 使用 `show processlist;` 其中的 Command 列显示为“Sleep”的这一行，就表示现在系统里面有一个空闲连接
- 客户端如果太长时间没动静，连接器就会自动将它断开。这个时间是由参数 `wait_timeout` 控制的，默认值是 8 小时
  - 如果在连接被断开之后，客户端再次发送请求的话，就会收到一个错误提醒： Lost connection to MySQL server during query。这时候如果要继续，就需要重连，然后再执行请求
- 数据库`长连接` 、`短连接`
  - 长连接是指连接成功后，如果客户端持续有请求，则一直使用同一个连接
    - 建立连接的过程通常是比较复杂的，所以建议你在使用中要尽量减少建立连接的动作，也就是尽量使用长连接
  - 短连接则是指每次执行完很少的几次查询就断开连接，下次查询再重新建立一个
- 全部使用长连接后，可能会导致 MySQL 占用内存涨得特别快
  - 原因： MySQL 在执行过程中临时使用的**内存是管理在连接对象里面的**。这些资源会在**连接断开的时候才释放**。所以如果长连接累积下来，可能导致内存占用太大，被系统强行杀掉（OOM），从现象看就是 MySQL 异常重启了。
  - 解决方法：
    - 定期断开长连接，使用一段时间，或者程序里面判断执行过一个占用内存的大查询后，断开连接，之后要查询再重连。
    - MySQL 5.7 或更新版本，可以在每次执行比较大的操作后，通过执行 `mysql_reset_connection` 来重新**初始化连接资源**
      - 这个过程**不需要重连和重新做权限验证**
      - 会将连接恢复到刚刚创建完时的状态
      **注：mysql_reset_connection是mysql为各个编程语言提供的api，不是sql语句**

```
mysql> show processlist;
+----+------+------------------+-------+---------+------+----------+------------------+
| Id | User | Host             | db    | Command | Time | State    | Info             |
+----+------+------------------+-------+---------+------+----------+------------------+
|  2 | root | localhost        | NULL  | Query   |    0 | starting | show processlist |
|  3 | root | 172.17.0.1:33260 | mysql | Sleep   |    4 |          | NULL             |
|  4 | root | 172.17.0.1:33262 | mysql | Sleep   |    4 |          | NULL             |
+----+------+------------------+-------+---------+------+----------+------------------+

# MySQL各timeout参数
mysql> SHOW VARIABLES LIKE '%timeout%';
+-----------------------------+----------+
| Variable_name               | Value    |
+-----------------------------+----------+
| connect_timeout             | 10       |
| delayed_insert_timeout      | 300      |
| have_statement_timeout      | YES      |
| innodb_flush_log_at_timeout | 1        |
| innodb_lock_wait_timeout    | 50       |
| innodb_rollback_on_timeout  | OFF      |
| interactive_timeout         | 28800    |
| lock_wait_timeout           | 31536000 |
| net_read_timeout            | 30       |
| net_write_timeout           | 60       |
| rpl_stop_slave_timeout      | 31536000 |
| slave_net_timeout           | 60       |
| wait_timeout                | 28800    |
+-----------------------------+----------+
```



| 参数名称                                | 说明                                                         |
| :-------------------------------------- | ------------------------------------------------------------ |
| connect_timeout                         | 该参数控制与服务器建立连接的时候等待三次握手成功的超时时间，该参数主要是对于网络质量较差导致连接超时，建议外网访问波动较大可以提高该参数。 |
| delayed_insert_timeout                  | 指INSERT语句执行的超时时间。                                 |
| innodb_lock_wait_timeout                | 指锁等待的超时时间，该锁不同于死锁是指正常一个事务等待另外一个事务的S锁或者X锁的超时时间。 |
| innodb_rollback_on_timeout              | 当事务超时超过该参数后即会回滚，如果设置为OFF即只回滚事务的最后一个请求。 |
| interactive_timeout<br />wait_timeout   | mysql在关闭一个交互式/非交互式的连接之前所要等待的时间。建议不需要设置太长的时候，否则会占用实例的连接数资源。 |
| lock_wait_timeout                       | 指定尝试获取元数据锁的超时时间。                             |
| net_read_timeout<br />net_write_timeout | 指服务器端等待客户端发送的网络包和发送给客户端网络包的超时时间，这两个参数是对TCP/IP链接并且是Activity状态下的线程才有效的参数。 |
| slave_net_timeout                       | 备实例等待主服务器同步的超时时间，超时后中止同步并尝试重新连接。 |

### 查询缓存

- MySQL 拿到一个查询请求后，会先到查询缓存
- 之前执行过的语句及其结果可能会以 key-value 对的形式，被直接缓存在内存中
  - key: 查询语句
  - value: 查询结果
- 如果根据key(查询条件)命中缓存，直接返回对应的Value
- 否则就会继续后面的执行阶段，执行完成后，执行结果会被存入查询缓存中
- **使用缓存弊大于利**
  - **查询缓存的失效非常频繁**，只要有对一个表的更新，这个表上所有的查询缓存都会被清空
  - 查询缓存的命中率会非常低
  - 查询缓存适用于读多写少的场景，比如静态配置表
- query_cache_type
  - A value of 0 or **OFF** prevents caching or retrieval of cached results
  - A value of 1 or **ON** enables caching except of those statements that begin with **SELECT SQL_NO_CACHE**
  - A value of 2 or **DEMAND** causes caching of only those statements that begin with **SELECT SQL_CACHE**
- 可以将参数 query_cache_type 设置成 DEMAND，默认的 SQL 语句都不使用查询缓存
  对于确定要使用查询缓存的语句，可以用 SQL_CACHE 显式指定，如下：
```sql
select SQL_CACHE * from T where ID=10；
```
- **MySQL 8.0 版本删除了查询缓存功能**

### 分析器

```sql
select * from T where ID=10;
```

- 分析器先会做**词法分析**
  - MySQL 需要识别出里面的字符串分别是什么，代表什么
  - 通过**select**识别是查询语句
  - 将字符串**T**识别成表，字符串**ID**识别成列
- 分析器再做**语法分析**
  - 根据词法分析的结果，语法分析会根据**语法规则**，判断SQL是否满足MySQL语法
  - 如果不满足，将会收到错误`You have an error in your SQL syntax`错误

### 优化器

- 经过**分析器**，MySQL已经能理解要**做什么**，在开始执行之前，需要经过**优化器**的处理，达到**怎么做**
- 优化器会在表里存在多个索引的时候，选择使用哪个索引
- 优化器也会在多表关联的时候，决定各个表的连接顺序
- 优化器阶段完成后，语句的**执行方案**就已经能确定下来了，然后进入执行器阶段

### 执行器

- MySQL通过**分析器**能明白**做什么**，再通过**优化器**能明白**怎么做**，而**执行器**是负责语句的**具体执行**
- 首先会判断是否有执行权限，如果没有就会返回权限错误，**SELECT command denied to user**
  - 如果命中查询缓存，也会在查询缓存**返回**结果的时候，做权限验证
  - 优化器之前也会调用**precheck**做验证权限
- 如果有权限，那么将打开表继续执行
  - 打开表的时候，执行器会根据表的引擎定义，去**调用引擎提供的接口**
- 假设表T中，ID字段没有索引，执行器的执行流程如下
  - 调用InnoDB的引擎接口，获取表的第一行，判断ID是否为10
    - 如果不是则跳过，如果是则将这行存放在结果集中
  - 调用引擎接口获取下一行，重复上面的判断逻辑，直到获取到表的最后一行
  - 执行器将上面遍历过程中所有满足条件的行组成的记录集作为结果集返回给客户端
- rows_examined
  - 数据库的慢查询日志会有`rows_examined`字段
  - 在执行器每次调用引擎获取数据行的时候**累加**的（+1）
  - 有些场景，执行器调用一次，但在引擎内部则是扫描了很多行
    - 例如在InnoDB中，**一页有很多行数据**
  - 因此，**引擎扫描行数（引擎内部真正扫描的次数）跟rows_examined并不完全相同**

### 思考问题
```
如果表 T 中没有字段 k，而你执行了这个语句 select * from T where k=1, 
那肯定是会报“不存在这个列”的错误： “Unknown column ‘k’ in ‘where clause’”。
你觉得这个错误是在我们上面提到的哪个阶段报出来的呢？
```
**分析器**
### 参考资料
《MySQL实战45讲》
