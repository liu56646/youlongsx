package com.vm.app

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.vm.app.databinding.ItemVmBinding
import com.vm.core.VmGuestCatalog
import com.vm.core.VmInfo

/** 实例列表适配器。 */
class VmAdapter(
    private val onClick: (VmInfo) -> Unit,
    private val onLongClick: (VmInfo) -> Unit
) : RecyclerView.Adapter<VmAdapter.Holder>() {

    private val items = mutableListOf<VmInfo>()

    fun submit(list: List<VmInfo>) {
        items.clear()
        items.addAll(list.sortedBy { it.vmId })
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
        val binding = ItemVmBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        return Holder(binding)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        holder.bind(items[position])
    }

    override fun getItemCount(): Int = items.size

    inner class Holder(private val binding: ItemVmBinding) : RecyclerView.ViewHolder(binding.root) {

        fun bind(info: VmInfo) {
            val res = binding.root.resources
            binding.vmName.text = info.name
            binding.vmMeta.text = res.getString(
                R.string.vm_meta_fmt,
                info.vmId,
                VmGuestCatalog.displayNameOf(info.imageTag)
            )
            binding.vmState.text = res.getString(
                if (VmRuntime.isRunning(info.vmId)) R.string.state_running else R.string.state_stopped
            )
            binding.root.setOnClickListener { onClick(info) }
            binding.root.setOnLongClickListener {
                onLongClick(info)
                true
            }
        }
    }
}
