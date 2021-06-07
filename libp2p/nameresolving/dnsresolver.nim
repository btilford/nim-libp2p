## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import
  std/[streams, strutils, sets, sequtils],
  chronos, chronicles,
  dnsclientpkg/[protocol, types]

import
  nameresolver

logScope:
  topics = "libp2p dnsresolver"

type
  DnsResolver* = ref object of NameResolver
    nameServers*: seq[TransportAddress]

const unixPlatform = defined(linux) or defined(solaris) or
                     defined(macosx) or defined(freebsd) or
                     defined(netbsd) or defined(openbsd) or
                     defined(dragonfly)

#Cloudflare
const fallbackDnsServers = @[
  initTAddress("1.1.1.1:53"),
  initTAddress("1.0.0.1:53"),
  initTAddress("[2606:4700:4700::1111]:53")
]

proc getNameServers(self: DnsResolver): seq[TransportAddress] =
  if self.nameServers.len > 0: return self.nameServers

  trace "Getting nameservers"
  when unixPlatform:
    var resultSeq = newSeqOfCap[TransportAddress](3)
    try:
      for l in lines("/etc/resolv.conf"):
        let lineParsed = l.strip().split(maxsplit = 2)
        if lineParsed.len < 2: continue
        if lineParsed[0].startsWith('#'): continue

        if lineParsed[0] == "nameserver":
          resultSeq.add(initTAddress(lineParsed[1], Port(53)))

          if resultSeq.len > 2: break #3 nameserver max on linux
    except Exception as e:
      debug "Failed to get unix nameservers", error=e.msg
    finally:
      if resultSeq.len > 0:
        return resultSeq
      return fallbackDnsServers
  elif defined(windows):
    #TODO
    return fallbackDnsServers
  else:
    return fallbackDnsServers


proc questionToBuf(address: string, kind: QKind): seq[byte] =
  try:
    var
      header = initHeader()
      question = initQuestion(address, kind)

      requestStream = header.toStream()
    question.toStream(requestStream)

    let dataLen = requestStream.getPosition()
    requestStream.setPosition(0)

    var buf = newSeq[byte](dataLen)
    discard requestStream.readData(addr buf[0], dataLen)
    return buf
  except Exception as exc:
    info "Failed to created DNS buffer", msg = exc.msg
    return newSeq[byte](0)

proc getDnsResponse(
  dnsServer: TransportAddress,
  address: string,
  kind: QKind): Future[Response] {.async.} =

  let receivedDataFuture = newFuture[void]()

  proc datagramDataReceived(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.async, closure.} =
      receivedDataFuture.complete()

  let sock = 
    if dnsServer.family == AddressFamily.IPv6:
      newDatagramTransport6(datagramDataReceived)
    else:
      newDatagramTransport(datagramDataReceived)


  var sendBuf = questionToBuf(address, kind)

  if sendBuf.len == 0:
    raise newException(ValueError, "Incorrect DNS query")

  await sock.sendTo(dnsServer, addr sendBuf[0], sendBuf.len)
  await receivedDataFuture

  var
    rawResponse = sock.getMessage()
    dataStream = newStringStream()
  dataStream.writeData(addr rawResponse[0], rawResponse.len)
  dataStream.setPosition(0)
  return parseResponse(dataStream)

method resolveIp*(
  self: DnsResolver,
  address: string,
  port: Port,
  domain: Domain = Domain.AF_UNSPEC): Future[seq[TransportAddress]] {.async.} =

  let nameservers = getNameServers(self)
  trace "Resolving IP using DNS", address, nameservers, domain
  for server in nameservers:
    var responseFutures: seq[Future[Response]]
    if domain == Domain.AF_INET or domain == Domain.AF_UNSPEC:
      responseFutures.add(getDnsResponse(server, address, A))

    if domain == Domain.AF_INET6 or domain == Domain.AF_UNSPEC:
      let fut = getDnsResponse(server, address, AAAA)
      if server.family == AddressFamily.IPv6:
        trace "IPv6 DNS server, puting AAAA records first", server
        responseFutures.insert(fut)
      else:
        responseFutures.add(fut)

    var resolvedAddresses: OrderedSet[string]
    for fut in responseFutures:
      let resp = await fut
      for answer in resp.answers:
        resolvedAddresses.incl(answer.toString())
    if resolvedAddresses.len > 0:
      trace "Got IPs from DNS server", resolvedAddresses, server
      return resolvedAddresses.toSeq().mapIt(initTAddress(it, port))

  debug "Failed to resolve address, returning empty set"
  return @[]

method resolveTxt*(
  self: DnsResolver,
  address: string): Future[seq[string]] {.async.} =

  let nameservers = getNameServers(self)
  trace "Resolving TXT using DNS", address, nameservers
  for server in nameservers:
    let response = await getDnsResponse(server, address, TXT)
    if response.answers.len > 0:
      trace "Got TXT response", server, answer=response.answers.mapIt(it.toString())
      return response.answers.mapIt(it.toString())
  debug "Failed to resolve TXT, returning empty set"
  return @[]

proc new*(T: typedesc[DnsResolver]): T =
  T()
