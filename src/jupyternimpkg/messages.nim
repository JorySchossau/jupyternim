import json, strutils, times, random, hmac, nimSHA2, md5

type WireType * = enum
  Unknown  = 0
  Kernel_Info = 1
  Execute = 2

  Introspection = 3
  Completion = 4
  History = 5
  Complete = 6
  Comm_info = 7
  
  Status = 9
  Shutdown = 10

  Comm_Open = 21 # not defined in spec?

type ConnectionMessage * = object 
  ## The connection message the notebook sends when starting
  ip*: string
  signature_scheme*: string
  key*: string
  hb_port*,iopub_port*,shell_port*,stdin_port*,control_port*: int
  kernel_name*: string

template debug*(str:varargs[string, `$`]) =
  when not defined(release):
    let inst = instantiationinfo() 
    echo "[" & $inst.filename & ":" & $inst.line & "] ", str.join(" ")

const validx = [ 'A', 'B', 'C', 'D', 'E', 'F', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' ]
const validy = [ '8', '9', '0', 'B' ]
proc genUUID(nb,upper:bool = true):string =
  ## Generate a uuid version 4.
  ## If ``nb`` is false, the uuid is compatible with IPython console.
  result = if nb: "xxxxxxxxxxxx4xxxyxxxxxxxxxxxxxxx" else: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  for c in result.mitems:
    if c == 'y' : c = sample(validy)
    elif c == 'x': c = sample(validx)
  if not upper: result = result.toLowerAscii

proc sign(msg:string,key:string):string =
  ##Sign a message with a secure signature.
  result = hmac.hmac_sha256(key,msg).hex.toLowerAscii

proc parseConnMsg*(connfile:string):ConnectionMessage =
  let parsedconn = parseFile(connfile)
  result.ip = parsedconn["ip"].str
  result.signature_scheme = parsedconn["signature_scheme"].str
  result.key = parsedconn["key"].str
  result.hb_port = parsedconn["hb_port"].num.int
  result.iopub_port = parsedconn["iopub_port"].num.int
  result.shell_port = parsedconn["shell_port"].num.int
  result.stdin_port = parsedconn["stdin_port"].num.int
  result.control_port = parsedconn["control_port"].num.int
  result.kernel_name = parsedconn["kernel_name"].str
  # transport method??

proc `$`*(cm:ConnectionMessage):string=
  result = "ip: " & cm.ip &
            "\nsignature_scheme: " & cm.signature_scheme &
            "\nkey: " & cm.key &
            "\nhb_port: " & $cm.hb_port &
            "\niopub_port: " & $cm.iopub_port &
            "\nshell_port: " & $cm.shell_port &
            "\nstdin_port: " & $cm.stdin_port &
            "\ncontrol_port: " & $cm.control_port &
            "\nkernel_name: " & cm.kernel_name

type WireMessage * = object
  msg_type*: WireType # Convenience, this is not part of the spec
  ## Describes a raw message as passed by Jupyter/Ipython
  ident*: string # uuid
  signature*:string # hmac signature
  header*: JsonNode
  parent_header*: JsonNode
  metadata*: JsonNode
  content*: JsonNode
  extra*: string # Extra raw data

#proc receive_wire_msg*(c:TConnection):WireMessage =
proc decode*(raw:openarray[string]): WireMessage =
  ## decoedes a wire message as a seq of string blobs into a WireMessage object

  result.ident = raw[0]

  if( raw[1]!="<IDS|MSG>"): 
    debug "proc receive wire msg: Malformed message?? Follows:"
    debug raw
  
  else :
    result.signature = raw[2]
    result.header = parseJson(raw[3])
    result.parent_header = parseJson(raw[4])
    result.metadata = parseJson(raw[5])
    result.content = parseJson(raw[6])

    if result.header.hasKey("msg_type") : 
      case result.header["msg_type"].str:
      of "kernel_info_request": result.msg_type = WireType.Kernel_Info
      of "shutdown_request" : result.msg_type = WireType.Shutdown
      of "execute_request": result.msg_type = WireType.Execute
      of "inspect_request": result.msg_type = WireType.Introspection
      of "complete_request": result.msg_type = WireType.Completion
      of "history_request": result.msg_type = WireType.History
      of "is_complete_request": result.msg_type = WireType.Complete
      #of "comm_info_request": result.msg_type = WireType.Comm_info <- in spec 5.1
      of "comm_open":
        result.msg_type = WireType.Comm_Open
        debug "unused msg: comm_open"
      else: 
        result.msg_type = WireType.Unknown
        debug "Unknown WireMsg: ", result.header, " follows:" # Dump the header for unknown messages
        debug result.content
        debug "Unknown WireMsg End"

    else:
      debug "NO WIRE MESSAGE TYPE?"

proc getISOstr():string = getDateStr()&'T'&getClockStr()
    
proc encode*(reply_type:string, content:JsonNode,key:string, parent:varargs[WireMessage]): seq[string] =
  ## Encode a message following wire spec and sends using the connection specified

  let header: JsonNode = %* {
    "msg_id" : genUUID(), # typically UUID, must be unique per message
    "username" : "kernel",
    "session" : key.getmd5(), # using md5 of key as we passed it here already, SECURITY RISK?
    "date": getISOstr(), # ISO 8601 timestamp for when the message is created
    "msg_type" : reply_type,
    "version" : "5.0", # the message protocol version
  }

  var 
    metadata : JSonNode = %* { }
    maybeParent : WireMessage
  debug "the par lenght is", parent.len
  if parent.len == 0:
    maybeParent.ident = "kernel"
    maybeParent.header = %*{}
  else:
    maybeParent = parent[0]

  result = @[maybeParent.ident] # Add ident
  
  result &= "<IDS|MSG>" # add separator
  
  let secondpartreply = $header & $maybeParent.header & $metadata & $content
  result &= sign(secondpartreply,key) # add signature TODO
  result &= $header 
  result &= $maybeParent.header 
  result &= $metadata 
  result &= $content
  