module Data.Chain exposing (..)

import Date exposing (Date)
import Dict exposing (Dict)
import Http
import Json.Decode as Decode
import Json.Decode.Pipeline as Decode
import List.Extra
import ParseInt
import RemoteData exposing (RemoteData)
import Set
import Data.Michelson as Michelson


type alias Base58CheckEncodedSHA256 =
    String


type alias BlockID =
    Base58CheckEncodedSHA256


type alias OperationID =
    Base58CheckEncodedSHA256


type alias NetID =
    Base58CheckEncodedSHA256


type alias SourceID =
    Base58CheckEncodedSHA256


type alias Signature =
    Base58CheckEncodedSHA256


type alias TransactionID =
    Base58CheckEncodedSHA256


type alias ContractID =
    Base58CheckEncodedSHA256


type alias Fitness =
    List Int


type alias Timestamp =
    Date


type alias Block =
    { hash : BlockID
    , predecessor : BlockID
    , fitness : Fitness
    , timestamp : Timestamp
    , operations : Maybe (List (List OperationID))
    , net_id : NetID
    , level : Level
    }


type alias Operation =
    { hash : OperationID
    , netID : NetID
    , data : String
    }


type alias Level =
    Int


type alias Nonce =
    String


type SubOperation
    = Unknown Decode.Value
    | Endorsement BlockID Int
    | SeedNonceRevelation Level Nonce
    | Transaction TransactionID Int
    | Faucet TransactionID Nonce
    | Delegation Base58CheckEncodedSHA256


type alias ParsedOperation =
    { hash : OperationID
    , net_id : NetID
    , operations : List SubOperation
    , source : Maybe SourceID
    , signature : Maybe Signature
    }


type alias BlockOperations =
    List (List ParsedOperation)


type alias BlocksData =
    List (List Block)


type alias Key =
    { hash : Base58CheckEncodedSHA256
    , public_key : Base58CheckEncodedSHA256
    }


type alias Peer =
    { hash : Base58CheckEncodedSHA256
    , info : PeerInfo
    }


type alias PeerInfo =
    { value : Decode.Value
    , state : String
    , stat : PeerStats
    , trusted : Bool
    , score : Int
    , lastConnection : Maybe Connection
    }


type alias Connection =
    { addr : Address
    , time : Timestamp
    }


type alias Address =
    { addr : String
    , port_ : Int
    }


type alias PeerStats =
    { total_sent : Int
    , total_recv : Int
    , current_inflow : Int
    , current_outflow : Int
    }


type alias Delegate =
    { setable : Bool
    , value : Maybe ContractID
    }


type alias Contract =
    { raw : Decode.Value
    , counter : Int
    , balance : Int
    , spendable : Bool
    , manager : ContractID
    , delegate : Delegate
    , script : Maybe Michelson.Script
    , rawBody : String
    }


type alias Model =
    { heads : List BlockID
    , blocks : Dict BlockID Block
    , operations : Dict OperationID Operation
    , parsedOperations : Dict OperationID ParsedOperation
    , blockOperations : Dict BlockID (List OperationID)
    , contractIDs : RemoteData Http.Error (List ContractID)
    , keys : RemoteData Http.Error (List Key)
    , peers : RemoteData Http.Error (List Peer)
    , contract : RemoteData Http.Error Contract
    , contracts : Dict ContractID Contract
    }


init : Model
init =
    { heads = []
    , blocks = Dict.empty
    , operations = Dict.empty
    , parsedOperations = Dict.empty
    , blockOperations = Dict.empty
    , contractIDs = RemoteData.NotAsked
    , keys = RemoteData.NotAsked
    , peers = RemoteData.NotAsked
    , contract = RemoteData.NotAsked
    , contracts = Dict.empty
    }


blockNeedsOperations : Model -> BlockID -> Bool
blockNeedsOperations model blockHash =
    not (Dict.member blockHash model.blockOperations)


blocksNeedingOperations : Model -> List BlockID
blocksNeedingOperations model =
    let
        blockHashSet =
            Dict.toList model.blocks |> List.map Tuple.first |> Set.fromList

        blockOperHashSet =
            Dict.toList model.blockOperations |> List.map Tuple.first |> Set.fromList
    in
        Set.diff blockHashSet blockOperHashSet |> Set.toList


addBlockOperations : Model -> BlockID -> BlockOperations -> Model
addBlockOperations model blockhash operations =
    let
        blockOperations =
            Dict.insert blockhash (List.concat operations |> List.map .hash) model.blockOperations

        addOperation operation dict =
            Dict.insert operation.hash operation dict

        parsedOperations =
            List.foldr addOperation model.parsedOperations (List.concat operations)
    in
        { model | blockOperations = blockOperations, parsedOperations = parsedOperations }


loadBlocks : Model -> BlocksData -> Model
loadBlocks model blocksData =
    let
        newBlocks =
            List.foldl addChainBlocks model.blocks blocksData
    in
        { model | blocks = newBlocks }


{-| Load list of blocks known to be exactly the list of chain heads.
-}
loadHeads : Model -> BlocksData -> Model
loadHeads model headsData =
    let
        newModel =
            loadBlocks model headsData

        heads : List BlockID
        heads =
            List.map List.head headsData
                |> List.filterMap identity
                |> List.map .hash
    in
        { newModel | heads = heads }


{-| Given an incremental new chain (from "/blocks" API with monitor option),
update the list of heads. Look for an existing head that matches up with the
predecessory in the tail of that new chain. If found, replace that existing head
with the head of the new chain.

TODO: What if it's a new chain?

-}
updateHeads : Dict BlockID Block -> List Block -> List BlockID -> List BlockID
updateHeads blocks newChain heads =
    List.head newChain
        |> Maybe.andThen
            (\newhead ->
                List.Extra.last newChain
                    |> Maybe.map .predecessor
                    |> Maybe.map
                        (\newpredhash ->
                            case updateExistingHead newhead.hash newpredhash heads of
                                Just newHeads ->
                                    newHeads

                                Nothing ->
                                    insertHead blocks newhead heads
                        )
            )
        |> Maybe.withDefault heads


updateExistingHead : BlockID -> BlockID -> List BlockID -> Maybe (List BlockID)
updateExistingHead newHead predHash heads =
    List.Extra.findIndex (\h -> h == predHash) heads
        |> Maybe.map
            (\_ -> List.Extra.updateIf (\h -> h == predHash) (\_ -> newHead) heads)


insertHead : Dict BlockID Block -> Block -> List BlockID -> List BlockID
insertHead blocks newHead heads =
    case heads of
        [] ->
            []

        head :: tail ->
            let
                blockMaybe =
                    Dict.get head blocks
            in
                case blockMaybe of
                    Just block ->
                        if fitnessGreater newHead.fitness block.fitness then
                            newHead.hash :: head :: tail
                        else
                            head :: insertHead blocks newHead tail

                    Nothing ->
                        Debug.log "error: insertHead failed" heads


fitnessGreater : Fitness -> Fitness -> Bool
fitnessGreater a b =
    case ( a, b ) of
        ( [], [] ) ->
            False

        ( aFirst :: aRest, bFirst :: bRest ) ->
            if aFirst > bFirst then
                True
            else
                fitnessGreater aRest bRest

        _ ->
            Debug.log ("error: fitnessGreater: " ++ toString ( a, b )) False


updateMonitor : Model -> BlocksData -> Model
updateMonitor model headsData =
    let
        newModel =
            loadBlocks model headsData

        newHeads =
            List.foldr (updateHeads newModel.blocks) newModel.heads headsData
    in
        { newModel | heads = newHeads }


addBlock : Block -> Dict BlockID Block -> Dict BlockID Block
addBlock block blocks =
    Dict.insert block.hash block blocks


addChainBlocks : List Block -> Dict BlockID Block -> Dict BlockID Block
addChainBlocks chain blocks =
    List.foldl addBlock blocks chain


head : Model -> Maybe BlockID
head model =
    List.head model.heads


{-| Get list of saved blocks starting with the block with given hash and
following predecessor links. This only finds blocks already in the dict.
-}
getBranchList : Model -> BlockID -> List Block
getBranchList model blockhash =
    let
        helper hash blockList =
            let
                blockMaybe =
                    Dict.get hash model.blocks
            in
                case blockMaybe of
                    Just block ->
                        if block.predecessor == hash then
                            -- this should happen only for the genesis block
                            blockList
                        else
                            helper block.predecessor (block :: blockList)

                    Nothing ->
                        blockList
    in
        helper blockhash [] |> List.reverse


loadOperation : Model -> Operation -> Model
loadOperation model operation =
    let
        newOperations =
            Dict.insert operation.hash operation model.operations
    in
        { model | operations = newOperations }


loadParsedOperation : Model -> OperationID -> ParsedOperation -> Model
loadParsedOperation model operationId operation =
    let
        newParsed =
            Dict.insert operationId operation model.parsedOperations
    in
        { model | parsedOperations = newParsed }


loadContractIDs : Model -> List ContractID -> Model
loadContractIDs model contractIDs =
    { model | contractIDs = RemoteData.Success contractIDs }


loadContractIDsError : Model -> Http.Error -> Model
loadContractIDsError model error =
    { model | contractIDs = RemoteData.Failure error }


loadingContractIDs : Model -> Model
loadingContractIDs model =
    { model | contractIDs = RemoteData.Loading }


loadingKeys : Model -> Model
loadingKeys model =
    { model | keys = RemoteData.Loading }


loadKeys : Model -> List Key -> Model
loadKeys model keys =
    { model | keys = RemoteData.Success keys }


loadKeysError : Model -> Http.Error -> Model
loadKeysError model error =
    { model | keys = RemoteData.Failure error }


loadingPeers : Model -> Model
loadingPeers model =
    { model | peers = RemoteData.Loading }


loadPeers : Model -> List Peer -> Model
loadPeers model peers =
    { model | peers = RemoteData.Success peers }


loadPeersError : Model -> Http.Error -> Model
loadPeersError model error =
    { model | peers = RemoteData.Failure error }


loadingContract : Model -> Model
loadingContract model =
    { model | contract = RemoteData.Loading }


loadContract : Model -> ContractID -> Contract -> Model
loadContract model contractId contract =
    { model
        | contract = RemoteData.Success contract
        , contracts = Dict.insert contractId contract model.contracts
    }


loadContractError : Model -> Http.Error -> Model
loadContractError model error =
    { model | contract = RemoteData.Failure error }



-- Decoders


decodeBlocks : Decode.Decoder BlocksData
decodeBlocks =
    Decode.field "blocks" (Decode.list (Decode.list decodeBlock))


decodeBlock : Decode.Decoder Block
decodeBlock =
    Decode.succeed Block
        |> Decode.required "hash" Decode.string
        |> Decode.required "predecessor" Decode.string
        |> Decode.required "fitness" decodeFitness
        |> Decode.required "timestamp" decodeTimestamp
        |> Decode.optional "operations"
            (Decode.list (Decode.list Decode.string) |> Decode.map Just)
            Nothing
        |> Decode.required "net_id" Decode.string
        |> Decode.required "level" Decode.int


decodeFitness : Decode.Decoder Fitness
decodeFitness =
    Decode.list decodeHexString


decodeHexString : Decode.Decoder Int
decodeHexString =
    Decode.string
        |> Decode.andThen
            (\hexString ->
                case ParseInt.parseIntHex hexString of
                    Ok int ->
                        Decode.succeed int

                    Err err ->
                        Decode.fail (toString err)
            )


decodeTimestamp : Decode.Decoder Timestamp
decodeTimestamp =
    Decode.string
        |> Decode.map Date.fromString
        |> Decode.andThen
            (\dateResult ->
                case dateResult of
                    Ok date ->
                        Decode.succeed date

                    Err error ->
                        Decode.fail error
            )


decodeLevel : Decode.Decoder Int
decodeLevel =
    Decode.at [ "ok", "level" ] Decode.int


decodeContractIDs : Decode.Decoder (List ContractID)
decodeContractIDs =
    Decode.field "ok" (Decode.list Decode.string)


decodeKey : Decode.Decoder Key
decodeKey =
    Decode.succeed Key
        |> Decode.required "hash" Decode.string
        |> Decode.required "public_key" Decode.string


decodeKeys : Decode.Decoder (List Key)
decodeKeys =
    Decode.field "ok" (Decode.list decodeKey)


decodePeers : Decode.Decoder (List Peer)
decodePeers =
    Decode.list decodePeer


type Item
    = ItemString String
    | ItemValue PeerInfo


decodePeer : Decode.Decoder Peer
decodePeer =
    let
        decodeString =
            Decode.map ItemString Decode.string

        decodeValue =
            Decode.map ItemValue decodePeerInfo

        decodeItem =
            Decode.oneOf [ decodeString, decodeValue ]
    in
        Decode.list decodeItem
            |> Decode.andThen
                (\list ->
                    case list of
                        [ ItemString string, ItemValue value ] ->
                            Decode.succeed (Peer string value)

                        _ ->
                            Decode.fail "bad peer"
                )


decodePeerInfo : Decode.Decoder PeerInfo
decodePeerInfo =
    Decode.value
        |> Decode.andThen
            (\value ->
                Decode.succeed PeerInfo
                    |> Decode.hardcoded value
                    |> Decode.required "state" Decode.string
                    |> Decode.required "stat" decodePeerStats
                    |> Decode.required "trusted" Decode.bool
                    |> Decode.required "score" Decode.int
                    |> Decode.optional "last_established_connection" (Decode.map Just decodeConnection) Nothing
            )


decodePeerStats : Decode.Decoder PeerStats
decodePeerStats =
    Decode.succeed PeerStats
        |> Decode.required "total_sent" Decode.int
        |> Decode.required "total_recv" Decode.int
        |> Decode.required "current_inflow" Decode.int
        |> Decode.required "current_outflow" Decode.int


type AddressItem
    = AddressTime Timestamp
    | AddressAddr Address


decodeConnection : Decode.Decoder Connection
decodeConnection =
    let
        decodeAddrItem =
            Decode.oneOf
                [ Decode.map AddressTime decodeTimestamp
                , Decode.map AddressAddr decodeAddress
                ]
    in
        Decode.list decodeAddrItem
            |> Decode.andThen
                (\list ->
                    case list of
                        [ AddressAddr addr, AddressTime time ] ->
                            Decode.succeed (Connection addr time)

                        _ ->
                            Decode.fail "address decode failed"
                )


decodeAddress : Decode.Decoder Address
decodeAddress =
    Decode.succeed Address
        |> Decode.required "addr" Decode.string
        |> Decode.required "port" Decode.int


decodeContract : Decode.Decoder Contract
decodeContract =
    -- Get raw value first so we can save it with the data for debugging.
    Decode.value
        |> Decode.andThen
            (\raw ->
                Decode.field "ok"
                    (Decode.succeed Contract
                        |> Decode.hardcoded raw
                        |> Decode.required "counter" Decode.int
                        |> Decode.required "balance" Decode.int
                        |> Decode.required "spendable" Decode.bool
                        |> Decode.required "manager" Decode.string
                        |> Decode.required "delegate" decodeDelegate
                        |> Decode.optional "script" (Michelson.decodeScript |> Decode.map Just) Nothing
                        |> Decode.hardcoded "[placeholder]"
                    )
            )


decodeContractResponse : Http.Response String -> Result String Contract
decodeContractResponse response =
    -- Decode full response so we can save the raw string body for viewing later
    Decode.decodeString decodeContract response.body
        |> Result.map
            (\contract ->
                { contract | rawBody = response.body }
            )


decodeDelegate : Decode.Decoder Delegate
decodeDelegate =
    Decode.succeed Delegate
        |> Decode.required "setable" Decode.bool
        |> Decode.optional "value" (Decode.string |> Decode.map Just) Nothing
