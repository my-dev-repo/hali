-- code highly referenced from https://github.com/facebook/SCRNNs/blob/master/mfactory.lua
-- http://arxiv.org/pdf/1412.7753v2.pdf
local models = {}

function models.makeModel(params, dict, n_classes)
  -- [[ input ]]
  -- params: table of hyperparameters for model
  -- dict : the data dictionary
  -- n_classes : (optional) the # of output classes
  -- [[ output ]]
  -- model_nets : model
  -- intern_layers : pointer to the internal layers of the model

  local n_classes = n_classes or dict.index_to_freq:size(1)
  local n_hidden = params.n_hidden
  local enc, dec, dec_loss
  local internal_layers = {}

  -- Standard Recurrent Neural Networks
  if string.find(params.name, 'srn') then
    -- [[ Encoder ]]
    enc = nn.Sequential()

    -- nn.ParallelTable()
    --  +----------+        +-----------+        +-----------+
    --  | {input1, +--------> {member1, |-------->           |
    --  |          |        |           |        | CAddTable |------>
    --  |  input2} +-------->  member2} |-------->           |
    --  +----------+        +-----------+        +-----------+
    local net_parallel = nn.ParallelTable()
    -- LookupTable : a particular case of a convolution, where the width of the convolution would be 1.
    -- input is a 1D or 2D tensor filled with **indices**.
    -- d : fixed dictionary containing d tokens (n_classes)
    -- m : hidden layer size (n_hidden)
    -- A : m × d token embedding matrix
    local embed = nn.LookupTableGPU(n_classes, n_hidden) -- A x_t
    -- R : m × m matrix of recurrent weights
    local project = nn.LinearNB(n_hidden, n_hidden) -- R h_{t-1}

    net_parallel:add(embed)
    net_parallel:add(project)
    enc:add(net_parallel)
    enc:add(nn.CAddTable()) -- A x_t + R h_{t-1}
    -- n_classes, n_hidden = 2, 5
    --
    -- net_parallel:forward{torch.Tensor{1}, torch.Tensor{1,1,1,1,1}}
    -- {
    --   1 : DoubleTensor - size: 1x5
    --   2 : DoubleTensor - size: 5
    -- }
    -- enc:forward{torch.Tensor{1}, torch.Tensor{1,1,1,1,1}}
    -- [torch.DoubleTensor of size 1x5]
    
    if params.non_linearity == 'relu' then
      enc:add(nn.Threshold()) -- Rectifier unit, max(0, x)
    elseif params.non_linearity == 'sigmoid' then
      enc:add(nn.Sigmoid()) -- h_t = sigmoid(A x_t + R h_{t-1})
    else
      error("Wrong non-linearity " .. params.non_linearity)
    end

    -- [[ Decoder ]]
    if string.find(params.name, '_sm') then
      dec = nn.Sequential()
      -- nn.LinearNB : just same as nn.Linear() but fbnn implementation
      dec.add(nn.LinearNB(n_hidden, n_classes))
      dec.add(nn.LogSoftMax())
    elseif string.find(params.name, '_hsm') then
      decloss = nn.HSM(dict.mapping, n_hidden)
    else
      error('wrong model name: should include `_sm` or `_hsm`')
    end
    
    intern_layers.embed = embed
    intern_layers.project = project

  elseif string.find(params.name, 'lstm') then
    -- input : a table {x_t, {h_{t-1}, c_{t-1}}}
    -- x_t : current input (1-of-N vector)
    -- h_{t-1} : previous set of hidden units
    -- c_{t-1} : memory units
    -- 
    -- Detailed computation :
    -- i = logistic(W_{xi} x_t + W_{hi} h_{t-1})
    -- f = logistic(W_{xf} x_t + W_{hf} h_{t-1})
    -- o = logistic(W_{xo} x_t + W_{ho} h_{t-1})
    -- g = th(W_{xg} x_t + W_{hg} H_{t-1})
    -- c_t = f .* c_{t-1} + i .* g
    -- h_t = o .* th(c_t)

    -- output : a table {h_t, c_t}
    -- h_t : current hidden state
    -- c_t : updated memory units

    -- In a batch setting,
    -- B : mini-batch size
    -- D : size of hidden/memory state
    -- x_t : D dimension
    -- h_{t-1}, c_{t-1} : BxD dimension

    -- from fbcunn
    -- Fast lookup table, supporting both CPU and GPU modes.
    -- http://facebook.github.io/fbcunn/fbcunn/#fbcunn.fbcunn.LookupTableGPU.dok
    local embed1 = nn.LookupTableGPU(n_classes, n_hidden) -- W_{xi}
    local embed2 = nn.LookupTableGPU(n_classes, n_hidden) -- W_{xf}
    local embed3 = nn.LookupTableGPU(n_classes, n_hidden) -- W_{xo}
    local embed4 = nn.LookupTableGPU(n_classes, n_hidden) -- W_{xg}

    local project1 = nn.LookupTableGPU(n_hidden, n_hidden) -- W_{hi}
    local project2 = nn.LookupTableGPU(n_hidden, n_hidden) -- W_{hf}
    local project3 = nn.LookupTableGPU(n_hidden, n_hidden) -- W_{ho}
    local project4 = nn.LookupTableGPU(n_hidden, n_hidden) -- W_{hg}

    -- Input Encoder: {x_t, {h_{t-1}, c_{t-1}}}
    -- Output Encoder: {h_t, c_t}
    -- Input Decoder: h_t
    -- Output Decoder: o_t

    -- construct LSTM graph: encoder
    local lstm_symbol = nn.Identity()() -- x_t
    local lstm_prev_state = nn.Identity()() -- H_{t-1} + c_{t-1}

    -- split into two tables
    local prev_hidden, prev_memory = lstm_prev_state:split(2) -- H_{t-1} + c_{t-1}
    local embed1n = embed1(lstm_symbol) -- W_{xi} x_t 
    local embed2n = embed2(lstm_symbol) -- W_{xf} x_t 
    local embed3n = embed3(lstm_symbol) -- W_{xo} x_t 
    local embed4n = embed4(lstm_symbol) -- W_{xg} x_t 

    local project1n = project1(prev_hidden) -- W_{hi} H_{t-1}
    local project2n = project2(prev_hidden) -- W_{hf} H_{t-1}
    local project3n = project3(prev_hidden) -- W_{ho} H_{t-1}
    local project4n = project4(prev_hidden) -- W_{hg} H_{t-1}

    local gate_i = nn.Sigmoid()(nn.CAddTable(){project1n, embed1n}) -- logistic(W_{xi} x_t + W_{hi} H_{t-1})
    local gate_f = nn.Sigmoid()(nn.CAddTable(){project2n, embed2n}) -- logistic(W_{xf} x_t + W_{hf} H_{t-1})
    local gate_o = nn.Sigmoid()(nn.CAddTable(){project3n, embed3n}) -- logistic(W_{xf} x_t + W_{hf} H_{t-1})
    local gate_g = nn.Tanh()(nn.CAddTable(){project4n, embed4n}) -- tanh(W_{xf} x_t + W_{hf} H_{t-1})

    -- c_t
    local new_memory = nn.CAddTable()({nn.CMulTable()({gate_f, prev_memory}), -- f .* c_{t-1}
                                       nn.CMulTable()({gate_i, gate_g})}) -- i .* g
    -- h_t
    local new_hidden = nn.CMulTable()({gate_o, nn.Tanh()(new_mem)}) -- o .* tanh(c_t)

    -- h_t + c_t
    local next_state = nn.Identity(){new_hidden, new_memory}

    -- [[ Encoder ]]
    -- input : {x_t, {h_{t-1}, c_{t-1}}}
    -- output : {h_t, c_t}
    enc = nn.gModule({lstm_symbol, lstm_prev_state}, {next_state})

    -- [[ Decoder ]]
    -- The decoder takes the current hidden state h_t and computes
    -- the log prob over the classes o_t.
    if string.find(params.name, '_sm') then
      dec = nn.Sequential()
      dec:add(nn.Linear(n_hidden, n_classes))
      dec:add(nn.LogSoftMax())
    elseif string.find(params.name, '_hsm') then
      -- from fbnn
      -- Hierarchical soft max with minibatches.
      -- https://github.com/facebook/fbnn/blob/master/fbnn/HSM.lua
      decloss = nn.HSM(dict.mapping, n_hidden)
    else
      error('wrong model name: should include `_sm` or `_hsm`')
    end

    -- intern_layers: pointers to the internal layers of the model
    internal_layers.embed1 = embed1n -- W_{xi} x_t
    internal_layers.embed2 = embed2n
    internal_layers.embed3 = embed3n
    internal_layers.embed4 = embed4n

    internal_layers.project1 = project1n -- W_{hi} H_{t-1}
    internal_layers.project2 = project2n
    internal_layers.project3 = project3n
    internal_layers.project4 = project4n
  end

  local model_nets = {
    encoder = enc,
    decoder = dec,
    decoder_with_loss = decloss
  }

  return model_nets, internal_layers
end

return models
